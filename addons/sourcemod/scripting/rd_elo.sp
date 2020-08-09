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
#define DEFAULT_ELO 1500
#define MAP_RESTART_DELAY 6
#define MAP_PRINT_DELAY 2
#define MAP_MAX_RESTARTS 3

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

// mapece
int mapEce = UNINITIALIZED;
int mapRetries = UNINITIALIZED;
char mapName[128];
bool mapStarted = false;

// team
int teamRetries = UNKNOWN;

// some convars we need to check
ConVar currentChallenge;
ConVar currentDifficulty;
ConVar aswVoteFraction;
ConVar readyOverride;
ConVar friendlyFireAbsorbtion;
ConVar hordeOnslaught;

// player scoreboard
int playerElo[MAXPLAYERS+1];
int playerPrevElo[MAXPLAYERS+1];
int playerActive[MAXPLAYERS+1];
int playerSteamId[MAXPLAYERS+1];
int playerRetries[MAXPLAYERS+1];
int playerRanking[MAXPLAYERS+1];

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
    readyOverride = FindConVar("rd_ready_mark_override");
    hordeOnslaught = FindConVar("asw_horde_override");
    friendlyFireAbsorbtion = FindConVar("asw_marine_ff_absorption");

    // convar hooks
    disableReadyOverride();

    HookConVarChange(currentChallenge, Event_OnSettingsChanged);
    HookConVarChange(currentDifficulty, Event_OnSettingsChanged);
    HookConVarChange(readyOverride, Event_OnSettingsChanged);
    HookConVarChange(hordeOnslaught, Event_OnSettingsChanged);
    HookConVarChange(friendlyFireAbsorbtion, Event_OnSettingsChanged);

    // disable map voting
    aswVoteFraction.SetFloat(2.0);
    
    // hook into events
    HookEvent("marine_selected", Event_OnMarineSelected);
    HookEvent("player_fullyjoined", Event_OnPlayerJoined);
    HookEvent("mission_success", Event_OnMapSuccess, EventHookMode_Pre);
    HookEvent("mission_failed", Event_OnMapFailed, EventHookMode_Pre);
    HookEvent("asw_mission_restart", Event_OnMapRestart, EventHookMode_Pre);

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
    return IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client) && playerActive[client] > 0;
}

/**
  * When a client connects, reset the slot with default data. This also
  * fetches ELO rating from the database.
  */
public void OnClientConnected(int client)
{
    if (playerElo[client] == UNKNOWN || playerElo[client] == UNINITIALIZED || !playerElo[client]) {
        if (IsClientConnected(client) && !IsFakeClient(client)) {
            // db
            int steamid = GetSteamAccountID(client);

            if (steamid) {
                // store steam id
                playerSteamId[client] = steamid;

                // fetch elo
                char query[256];
                FormatEx(query, sizeof(query), "SELECT elo, retry, last_map, FIND_IN_SET(elo, (SELECT GROUP_CONCAT(elo ORDER BY elo DESC) FROM player_score)) FROM player_score WHERE steamid = %d", steamid);
                PrintToServer("[ELO] %s", query);
                DBResultSet results = SQL_Query(db, query);

                int elo = DEFAULT_ELO;
                int retry = UNKNOWN;
                int rank = UNKNOWN;
                char lastMap[128];

                while (SQL_FetchRow(results)) {
                    elo = SQL_FetchInt(results, 0);
                    retry = SQL_FetchInt(results, 1);
                    rank = SQL_FetchInt(results, 3);
                    SQL_FetchString(results, 2, lastMap, sizeof(lastMap));
                }
                playerElo[client] = elo;
                playerPrevElo[client] = UNINITIALIZED;
                playerRanking[client] = rank;

                // if the last_map is the same as the current one, assign retry
                if (StrEqual(lastMap, mapName)) {
                    playerRetries[client] = retry;
                }

                delete results;
            }
        }
    }
}

/**
  * If a client disconnects, free the slot 
  *
  * OnClientDisconnect is triggered on map change, use the _Post
  * variance to make sure the client is not coming back
  */
public void OnClientDisconnect(client)
{
    // check if the player was playing
    if (playerActive[client] > 0 && mapStarted == true) {
        // player rq, award elo penalty
        int groupElo = calculateGroupElo();
        updatePlayerElo(client, groupElo, false);

        PrintToChatAll("[ELO] %N did quit during active game, awarding elo penalty");
    }

    // erase the scoreboard, for the next client
    playerElo[client] = UNINITIALIZED;
    playerPrevElo[client] = UNINITIALIZED;
    playerActive[client] = UNKNOWN;
    playerSteamId[client] = UNKNOWN;
    playerRetries[client] = UNKNOWN;
}

/*****************************
 * Map related
 ****************************/

/**
  * Fetch the current map name
  */
public void OnMapStart()
{
    // check if ff and onslaught are on
    if (friendlyFireAbsorbtion.IntValue != 0) {
        PrintToChatAll("[ELO] friendly fire needs to be enabled for ranked game");
    } else if (hordeOnslaught.IntValue == 0) {
        PrintToChatAll("[ELO] onslaught needs to be enabled for ranked game");
    } else {

        // fetch current map and challenge
        GetCurrentMap(mapName, sizeof(mapName));

        char challenge[256];
        currentChallenge.GetString(challenge, sizeof(challenge));

        // if no challege, challenge will be 0
        if (StrEqual(challenge, "0")) {
            challenge = "";
        }

        // fetch map elo from db
        char query[256];
        FormatEx(query, sizeof(query), "SELECT score, retry_limit FROM map_score WHERE map_name = '%s' and challenge = '%s'", mapName, challenge);
        DBResultSet results = SQL_Query(db, query);

        PrintToServer("[ELO:db] %s", query);
        while (SQL_FetchRow(results)) {
            // params
            int dbEce = SQL_FetchInt(results, 0);
            int difficulty = currentDifficulty.IntValue;
            mapRetries = SQL_FetchInt(results, 1);
            
            if (difficulty < DIFFICULTY_HARD) {
                // disable for easy and normal
                mapEce = 0;
            } else if (difficulty == DIFFICULTY_HARD) {
                mapEce = RoundFloat(dbEce * 0.65);
            } else if (difficulty == DIFFICULTY_INSANE) {
                mapEce = RoundFloat(dbEce * 0.85);
            } else if (difficulty == DIFFICULTY_BRUTAL) {
                mapEce = dbEce;
            }
        }

        delete results;

        if (mapEce) {
            for (new i = 1; i < MaxClients; i++) {
                if (isValidPlayer(i)) {
                    ShowPlayerElo(i);
                }
            }

            PrintToChatAll("[ELO] map ece is %d with %d tries", mapEce, mapRetries);
        } else {
            PrintToChatAll("[ELO] unsupported map, difficulty or challenge");
        }
    }

    disableReadyOverride();


}

public void disableReadyOverride()
{
    if (readyOverride.IntValue > 0) {
        // readyOverride.SetInt(0);
    }
}

/**
  * Display ELO to players
  */
public void ShowPlayerElo(int client)
{
    CreateTimer(1.0, PrintPlayerElo, client);
}

public Action PrintPlayerElo(Handle timer, int client) {
    int elo = playerElo[client];
    int prevElo = playerPrevElo[client];

    if (prevElo == UNINITIALIZED || elo == prevElo) {
        if (playerRanking[client] == UNKNOWN) {
            PrintToChatAll("[ELO] %N has no ranking and has been set to %d elo", client, playerRanking[client], elo);
        } else {
            PrintToChatAll("[ELO] %N is ranked #%d and has %d elo", client, playerRanking[client], elo);
        }
    } else if (elo > prevElo) {
        PrintToChatAll("[ELO] %N has gained %d elo and has now %d", client, elo - prevElo, elo);
    } else {
        PrintToChatAll("[ELO] %N has lost %d elo and has now %d", client, prevElo - elo, elo);
    }
}

/*****************************
 * Events
 ****************************/

public void Event_OnSettingsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    // relay to map start
    OnMapStart();
}

public Action Event_OnPlayerJoined(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    
    if (!playerRanking[client]) {
        OnClientConnected(client);
    }
    ShowPlayerElo(client);
}

public Action Event_OnMarineSelected(Event event, const char[] name, bool dontBroadcast)
{
    // this gets triggered after mission_start, or in game if a player joins
    mapStarted = true;

    int numMarines = event.GetInt("count");
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);

    // re-fetch player's elo, in case it is unknown
    if (playerElo[client] == UNINITIALIZED || playerElo[client] == UNKNOWN) {
        OnClientConnected(client);
    }

    // display elo
    if (numMarines > 0) {
        // mark the player as playing
        playerActive[client] = numMarines;

        // display what flesh just joined
        ShowPlayerElo(client);
    }

    return Plugin_Continue;
}

public Action Event_OnMapRestart(Event event, const char[] name, bool dontBroadcast)
{
    // relay to map failed
    if (mapStarted) {
        return Event_OnMapFailed(event, name, dontBroadcast);
    } else {
        return Plugin_Continue;
    }
}

public Action Event_OnMapFailed(Event event, const char[] name, bool dontBroadcast)
{
    // group elo
    int groupElo = calculateGroupElo();

    if (mapStarted == true) {
        // raise fail scores only once every map 
        mapStarted = false;        
        bool mapChange = false;

        // iterate players
        for (new i = 1; i <= MaxClients; i++) {            
            if (isValidPlayer(i)) {
                
                playerRetries[i]++;
                if (playerRetries[i] > teamRetries) {
                    teamRetries = playerRetries[i];
                }

                updatePlayerRetry(i);

                if (playerRetries[i] >= mapRetries) {
                    // one player hit retry limit, probably whole lobby did
                    mapChange = true;
                }
            }
        }

        // change the map
        if (mapChange) {
            
            // award elo penalty
            for (new i = 1; i <= MaxClients; i++) { 
                // award if player was active and tried more than one time
                if (isValidPlayer(i) && playerRetries[i] > 1) {
                    updatePlayerElo(i, groupElo, false);
                }
            }

            CreateTimer(MAP_PRINT_DELAY - 0.2, Print_OnTeamFailed);
            CreateTimer(MAP_RESTART_DELAY + 0.0, changeRandomMap);
            return Plugin_Stop;
        }

        // display retry count
        CreateTimer(MAP_PRINT_DELAY + 0.0, Print_OnMapFailed);
    }
    
    return Plugin_Continue;
}

public Action Print_OnMapFailed(Handle timer)
{
    PrintToChatAll("[ELO] mission failed, try %d of %d", teamRetries, mapRetries);
}

public Action Print_OnTeamFailed(Handle timer)
{
    PrintToChatAll("[ELO] team failed too often, changing map..");
}

public Action Event_OnMapSuccess(Event event, const char[] name, bool dontBroadcast)
{
    // group elo
    int groupElo = calculateGroupElo();

    CreateTimer(MAP_PRINT_DELAY - 0.2, Print_OnMapSuccess);

    for (new i = 1; i <= MaxClients; i++) {
        if (isValidPlayer(i)) {
            // award elo
            updatePlayerElo(i, groupElo, true);
        }
        
        // erase scoreboard afterwards
        playerActive[i] = 0;
    }

    CreateTimer(MAP_RESTART_DELAY + 0.0, changeRandomMap);

    return Plugin_Stop;
}

public Action Print_OnMapSuccess(Handle timer)
{
    PrintToChatAll("[ELO] mission succeeded, awarding elo to active players");
}

/*****************************
 * Change level
 ****************************/
public Action changeRandomMap(Handle timer)
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
    PrintToServer("[ELO:db] %s", query);
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

public void updatePlayerRetry(int client)
{
    // escape map name
    char escapedMapName[256];
    db.Escape(mapName, escapedMapName, sizeof(escapedMapName));

    char query[512];
    FormatEx(query, sizeof(query), "UPDATE player_score set retry = %d, last_map = '%s' where steamid = %d", playerRetries[client], escapedMapName, playerSteamId[client]);
    PrintToServer("[ELO:db] %s", query);
    db.Query(dbQuery, query, client);
}

public void updatePlayerElo(int client, int groupElo, bool success)
{
    // calculate new elo
    playerPrevElo[client] = playerElo[client];
    int elo = calculateElo(client, groupElo, success);

    // write it to db
    if (elo > UNKNOWN) {
        // get some player information
        int steamid = playerSteamId[client];

        // store elo
        char query[1024];
        FormatEx(query, sizeof(query), "INSERT INTO player_score (steamid, elo) values (%d, %d) ON DUPLICATE KEY UPDATE elo = %d, retry = 0, last_map = ''", steamid, elo, elo);
        PrintToServer("[ELO:db] %s", query);
        db.Query(dbQuery, query, client);

        // if we can retrieve a name, update it
        if (isValidPlayer(client)) {
            char name[128];
            GetClientName(client, name, sizeof(name));

            // escape the player name properly
            char escapedName[256];
            db.Escape(name, escapedName, sizeof(escapedName));
            
            FormatEx(query, sizeof(query), "UPDATE player_score set name = '%s' where steamid = %d", escapedName, steamid);
            PrintToServer("[ELO:db] %s", query);
            db.Query(dbQuery, query, client);
        }

        playerElo[client] = elo;
        ShowPlayerElo(client);
    }

    // reset the player slot
    playerActive[client] = 0;
}

public int calculateElo(int client, int groupEloScore, bool success) 
{
    int currentElo = playerElo[client];
    float groupElo = groupEloScore + 0.0;
    float elo = currentElo + 0.0;
    float ece = mapEce + 0.0;

    // do not calculate if client is uninitialized
    if (currentElo == UNINITIALIZED) {
        // reconnect the client
        OnClientConnected(client);
    } else if (ece != UNINITIALIZED) {
        // success
        if (success == true) {
            float gain = (ece - groupElo + 600) / 10;
            if (gain <= 4.0) {
                elo = elo + 1.0;
            } else {
                elo = elo + 1.0 / (elo / groupElo) * gain;
            }
        } else {
            // failure
            float eloPenalty = (groupElo - ece + 600) / 10;
            if (eloPenalty > 0.0) {
                elo = elo - (elo / groupElo) * eloPenalty;
            }
        }
    }

    return RoundFloat(elo);
}
