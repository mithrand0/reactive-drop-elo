/*
    SourceMod RD Matchmaking & ELO
    Copyright (C) 2020 jhheight
    This program is private software. You are not allowed to use, modify, copy
    reverse engineer, duplicate or distribute it in any way without the explicit
    permission of the owner.
*/
#pragma semicolon 1

/* SM Includes */
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define VERSION "0.0.1"

/* Plugin Info */
public Plugin myinfo =
{
    name =          "AS:RD ELO",
    author =        "Mithrand, jhheight",
    description =   "ELO module for Reactive Drop",
    url =           "https://github.com/mithrand0",
    version =       VERSION
};

/*****************************
 * Constants
 ****************************/
#define UNINITIALIZED -1
#define UNKNOWN 0
#define DEFAULT_ELO 1000
#define RESTART_GRACE_TIME 30
#define MAP_MAX_ATTEMPTS 3
#define RAGE_DELAY 1

// difficulties
#define DIFFICULTY_NOTSET 0
#define DIFFICULTY_EASY 1
#define DIFFICULTY_NORMAL 2
#define DIFFICULTY_HARD 3
#define DIFFICULTY_INSANE 4
#define DIFFICULTY_BRUTAL 5


/*****************************
 * Global variables
 ****************************/

// team failure counter
int missionFailedCounter = 0;
int missionFailedTimestamp = UNINITIALIZED;

// round ece
int ece = UNINITIALIZED;

// player failure counter
int playerFailedCounter[MAXPLAYERS+1];

// some convars we need to check
ConVar currentChallenge;
ConVar currentDifficulty;
ConVar aswVoteFraction;

// player scoreboard
int playerElo[MAXPLAYERS+1];

// marine slot
int playerMarines[MAXPLAYERS+1];

// database handle
Database db;

/*****************************
 * Plugin start
 ****************************/

// on plugin start 
public void OnPluginStart()
{
    // connect to db
    connectDb();

    // hook some convars
    currentChallenge = FindConVar("rd_challenge");
    currentDifficulty = FindConVar("asw_skill");
    aswVoteFraction = FindConVar("asw_vote_map_fraction");

    // convar hooks
    HookConVarChange(currentChallenge, Event_OnSettingsChanged);
    HookConVarChange(currentDifficulty, Event_OnSettingsChanged);

    // disable map voting
    aswVoteFraction.SetFloat(2.0);
    
    // hook into events
    HookEvent("marine_selected", Event_OnMarineSelected);
    HookEvent("mission_success", Event_OnMapSuccess, EventHookMode_Pre);
    HookEvent("asw_mission_restart", Event_OnMapFailure, EventHookMode_Pre);
    HookEvent("mission_failed", Event_OnMapFailure, EventHookMode_Pre);

    // log
    PrintToServer("[ELO] initialized");
}

/*****************************
 * Database related
 ****************************/

/**
  * Connect to database
  */
public Action connectDb()
{
    char dbError[256];
    db = SQL_Connect("elo", true, dbError, sizeof(dbError));
    if (db == null) {
        PrintToServer("[ELO] connect error: %s, disabling plugin..", dbError);
        return Plugin_Stop;
    } else {
        PrintToServer("[ELO] connected to db");
    }

    return createDbSchema();
}

public Action createDbSchema()
{
    char query[256];
    
    query = "create table if not exists map_score (map_name varchar(255) NOT NULL, challenge varchar(255) NOT NULL, score int(11) NOT NULL, PRIMARY KEY (map_name,challenge))";
    SQL_Query(db, query);

    query = "create table if not exists player_score (steamid bigint(20) NOT NULL, elo int(11) NOT NULL, PRIMARY KEY (steamid))";
    SQL_Query(db, query);

    return Plugin_Continue;
}

public void dbQuery(Database handle, DBResultSet results, const char[] error, any data)
{
    if (!StrEqual(error, "")) {
        PrintToServer("[ELO] db error: %s", error);
    }
    delete results;
}

/*****************************
 * Player client functions
 ****************************/

public bool isValidPlayer(client)
{
    return IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client) && playerMarines[client] > 0;
}

/**
  * When a client connects, reset the slot with default data. This also
  * fetches ELO rating from the database.
  */
public void OnClientConnected(int client)
{
    playerFailedCounter[client] = 0;
    playerMarines[client] = UNINITIALIZED;

    if (IsClientConnected(client) && !IsFakeClient(client)) {
        // db
        int steamid = GetSteamAccountID(client);
        if (steamid) {
            char query[256];
            FormatEx(query, sizeof(query), "SELECT elo FROM player_score WHERE steamid = %d", steamid);
            PrintToServer("[ELO] %s", query);
            DBResultSet results = SQL_Query(db, query);

            int elo = DEFAULT_ELO;
            while (SQL_FetchRow(results)) {
                elo = SQL_FetchInt(results, 0);
            }

            delete results;
            playerElo[client] = elo;

            PrintToServer("[ELO] %L: %d elo", client, elo);
            PrintToChatAll("[ELO] %N has %d elo", client, elo);
        }
    }
}

/**
  * If a client disconnects, free the slot */
public void OnClientDisconnect(client)
{
    playerElo[client] = UNINITIALIZED;
    playerFailedCounter[client] = UNKNOWN;
    playerMarines[client] = UNKNOWN;
}

/*****************************
 * Map related
 ****************************/

/**
  * Fetch the current map name
  */
public void OnMapStart()
{
    int mapEce = UNINITIALIZED;

    // fetch current map and challenge
    char map[256];
    GetCurrentMap(map, sizeof(map));

    char challenge[256];
    currentChallenge.GetString(challenge, sizeof(challenge));

    // if no challege, challenge will be 0
    if (StrEqual(challenge, "0")) {
        challenge = "";
    }

    // fetch map elo from db
    char query[256];
    FormatEx(query, sizeof(query), "SELECT score FROM map_score WHERE map_name = '%s' and challenge = '%s'", map, challenge);
    DBResultSet results = SQL_Query(db, query);

    PrintToServer("[ELO] query: %s", query);
    while (SQL_FetchRow(results)) {
        // params
        int dbEce = SQL_FetchInt(results, 0);
        int difficulty = currentDifficulty.IntValue;
        
        if (difficulty < DIFFICULTY_HARD) {
            // disable for easy and normal
            PrintToServer("[ELO] difficulty too low, disabling ece");
            mapEce = 0;
        } else if (difficulty == DIFFICULTY_HARD) {
            mapEce = RoundFloat(dbEce * 0.65);
        } else if (difficulty == DIFFICULTY_INSANE) {
            mapEce = RoundFloat(dbEce * 0.85);
        } else if (difficulty == DIFFICULTY_BRUTAL) {
            mapEce = dbEce;
        }
    }

    ece = mapEce;
    delete results;

    PrintToServer("[ELO] calculated map ece %d", ece);
}

/*****************************
 * Events
 ****************************/

public void Event_OnSettingsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    PrintToServer("[ELO] settings have changed");
    
    // relay to map start
    OnMapStart();
}

public Action Event_OnMarineSelected(Event event, const char[] name, bool dontBroadcast)
{
    PrintToServer("[ELO] marine selected");
    int marines = event.GetInt("count");
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);

    PrintToServer("[ELO] %L has selected %d marines", client, marines);

    // assign marine slot
    playerMarines[client] = marines;

    // refire connect event
    OnClientConnected(client);

    return Plugin_Continue;
}

public Action Event_OnMapFailure(Event event, const char[] name, bool dontBroadcast)
{
    // group elo
    int groupElo = calculateGroupElo();

    // if failure was repeated within grace time, don't count
    int currentTime = RoundFloat(GetEngineTime());

    PrintToServer("[ELO] current %d, previous %d", currentTime, missionFailedTimestamp);
    if (currentTime > missionFailedTimestamp) {
        
        // raise fail scores
        missionFailedCounter++;
        missionFailedTimestamp = currentTime + RESTART_GRACE_TIME;

        for (new i = 1; i <= MaxClients; i++) {
            if (isValidPlayer(i)) {
                // raise fail counters
                if (playerFailedCounter[i] < 1) {
                    playerFailedCounter[i] = 1;
                } else {
                    playerFailedCounter[i]++;
                }

                // award elo penalty to player
                if (playerFailedCounter[i] > MAP_MAX_ATTEMPTS) {
                    PrintToServer("[ELO] %L awarded elo penalty", i);
                    updatePlayerElo(i, groupElo, false);
                    playerFailedCounter[i] = 0;
                }
            }
        }
    }

    if (missionFailedCounter > MAP_MAX_ATTEMPTS) {
        changeRandomMap();
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

public Action Event_OnMapSuccess(Event event, const char[] name, bool dontBroadcast)
{
    // reset fail retries
    missionFailedCounter = 0;
    missionFailedTimestamp = UNKNOWN;

    // group elo
    int groupElo = calculateGroupElo();

    for (new i = 1; i <= MaxClients; i++) {
        if (isValidPlayer(i)) {
            playerFailedCounter[i] = 0;

            // award elo
            updatePlayerElo(i, groupElo, true);
        }
    }

    changeRandomMap();

    return Plugin_Handled;
}



/*****************************
 * Change level
 ****************************/
public Action changeRandomMap()
{
    // fetch current map and challenge
    char map[256];
    GetCurrentMap(map, sizeof(map));

    char challenge[256];
    currentChallenge.GetString(challenge, sizeof(challenge));

    // if no challege, challenge will be 0
    if (StrEqual(challenge, "0")) {
        challenge = "";
    }

    // fetch a random map
    char query[256];
    FormatEx(query, sizeof(query), "SELECT map_name FROM map_score WHERE map_name != '%s' and challenge = '%s' order by rand() limit 1", map, challenge);
    PrintToServer("[ELO] %s", query);
    DBResultSet results = SQL_Query(db, query);

    while (SQL_FetchRow(results)) {
        char newMap[128];
        SQL_FetchString(results, 0, newMap, sizeof(newMap));

        char command[192];
        FormatEx(command, sizeof(command), "changelevel %s", newMap);
        ServerCommand(command);
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

/*****************************
 * Score related
 ****************************/

public int calculateGroupElo()
{
    int totalElo = 0;
    int totalSpectatorElo = 0;
    int players = 0;
    int spectators = 0;

    for (new i = 1; i <= MaxClients; i++) {
        if (isValidPlayer(i)) {
            totalElo += playerElo[i];
            players++;
        }
        totalSpectatorElo += playerElo[i];
        spectators++;
    }

    // they all went afk
    if (players == UNKNOWN) {
        players = spectators;
        totalElo = totalSpectatorElo;
    }

    return RoundFloat(totalElo / players + 0.0);
}

public Action updatePlayerElo(int client, int groupElo, bool success)
{
    // calculate new elo
    int elo = calculateElo(client, groupElo, success);

    // write it to db
    if (elo > UNKNOWN) {
        int steamid = GetSteamAccountID(client);
        char query[1024];
        FormatEx(query, sizeof(query), "REPLACE INTO player_score (steamid, elo) values (%d, %d)", steamid, elo);
        SQL_Query(db, query);
    }

    return Plugin_Continue;
}



public int calculateElo(int client, int groupElo, bool success) 
{
    int currentElo = playerElo[client];
    float elo = currentElo + 0.0;

    // do not calculate if client is uninitialized
    if (playerElo[client] == UNINITIALIZED) {
        // reconnect the client
        OnClientConnected(client);
    } else if (ece != UNINITIALIZED) {
        // success
        if (success == true) {
            float gain = (ece - groupElo + 600) / 10 + 0.0;
            if (gain <= 4) {
                elo = currentElo + 1.0;
            } else {
                elo = currentElo + 1.0 / (currentElo / groupElo) * gain;
            }
        } else {
            // failure
            float eloPenalty = (groupElo - ece + 600) / 10 + 0.0;
            if (eloPenalty > 0) {
                elo = currentElo - (currentElo / groupElo) * eloPenalty;
            }
        }
    }

    return RoundFloat(elo);
}
