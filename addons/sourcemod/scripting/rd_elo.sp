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

#define VERSION "0.11.1"

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
#define DEFAULT_ELO 1200
#define OFFSET_ELO 600
#define MAP_RESTART_DELAY 6
#define MAP_PRINT_DELAY 2

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
int mapId = UNINITIALIZED;
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
int playerRanking[MAXPLAYERS+1];
int playerHealthRemaining[MAXPLAYERS+1];

// player bonusses
int playerRetries[MAXPLAYERS+1];   // elo penalty after 3rd (asbi 4th) retry, or 10% additional loss immediately on ragequit
int playerTeamKills[MAXPLAYERS+1]; // elo penalty after > 2 team kills per mission or 10% additional loss immediately on ragequit
int playerAlienDamageTaken[MAXPLAYERS+1]; // negative bonus if damage > 100 (0.2x elo x damage taken)
int playerTeamDamageDone[MAXPLAYERS+1]; // negative bonus if damage > 200 (0.1x elo x damage done)
int playerSuicide[MAXPLAYERS+1];  // exclusion from mission success elo when no kills/heals bonus achieved. 10% additional loss after 3rd retry.
int playerTeamHeals[MAXPLAYERS+1]; // individual bonus on top of map ece with maximum at 100
int playerAlienKills[MAXPLAYERS+1]; // max bonus at 100
int playerTeamInfestedCures[MAXPLAYERS+1]; // bonus cured marines * 10
int playerFastReloadExpert[MAXPLAYERS+1];  // one time +10 after 5th fast reload
int playerAchievementEarned[MAXPLAYERS+1]; // +10 for every achievement (does this trigger is already achieved?)
int playerBeaconsPlaced[MAXPLAYERS+1]; // +2 for every deployment (heal/amplify)
int playerAmmoDeployments[MAXPLAYERS+1]; // see above, ammo
int playerTeamExtinguishes[MAXPLAYERS+1]; // player has extinguised another player

// player state
int playerDied[MAXPLAYERS+1]; // incicates the player died
int playerRageQuit[MAXPLAYERS+1]; // player has rage quit

// team bonusses
// int teamUsesTesla;
// int teamUsesFlamer;
// int teamUsesGrenadeLauncher;

// database handle
Database db;

// debug message
bool debugEnabled = false;
char debugMessage[512];

// event hooks
new String:eventHooksPost[][] = {
    "achievement_earned",
    "alien_died",
    "damage_amplifier_placed",
    "fast_reload",
    "heal_beacon_placed",
    "marine_hurt",
    "marine_extinguished",
    "marine_infested_cured",
    "marine_selected",
    "player_fullyjoined",
    "player_heal",
    "player_heal_target",
    "player_deploy_ammo"
};

new String:eventHooksPre[][] = {
    "asw_mission_restart",
    "mission_failed",
    "mission_success"
};


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
    
    // hook into pre events
    for (new v=0; v<sizeof(eventHooksPre); v++) {
        HookEvent(eventHooksPre[v], Event_Dispatcher, EventHookMode_Pre);
    }

    // hook into post events
    for (new v=0; v<sizeof(eventHooksPost); v++) {
        HookEvent(eventHooksPost[v], Event_Dispatcher, EventHookMode_Post);
    }

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

public bool isValidPlayer(int client)
{
    return IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client) && isActivePlayer(client);
}

public bool isActivePlayer(int client)
{
    if (client == UNKNOWN || client > MAXPLAYERS) {
        return false;
    } else {
        return playerActive[client] > 0;
    }
}

/**
  * When a client connects, reset the slot with default data. This also
  * fetches ELO rating from the database.
  */
public void OnClientConnected(int client)
{
    // logging
    FormatEx(debugMessage, sizeof(debugMessage), "OnClientConnected trigged");
    printDebugMessage(client);

    if (playerElo[client] == UNKNOWN || playerElo[client] == UNINITIALIZED || !playerElo[client]) {
        if (IsClientConnected(client) && !IsFakeClient(client)) {
            // db
            int steamid = GetSteamAccountID(client);

            if (steamid) {
                // store steam id
                playerSteamId[client] = steamid;

                // fetch elo
                char query[256];
                FormatEx(query, sizeof(query), "SELECT elo, scoreboard, FIND_IN_SET(elo, (SELECT GROUP_CONCAT(elo ORDER BY elo DESC) FROM player_score)) FROM player_score WHERE steamid = %d", steamid);
                PrintToServer("[ELO] %s", query);
                DBResultSet results = SQL_Query(db, query);

                int elo = DEFAULT_ELO;
                int rank = UNKNOWN;
                char scoreboard[256];

                while (SQL_FetchRow(results)) {
                    elo = SQL_FetchInt(results, 0);
                    SQL_FetchString(results, 1, scoreboard, sizeof(scoreboard));
                    rank = SQL_FetchInt(results, 2);
                }
                playerElo[client] = elo;
                playerPrevElo[client] = UNINITIALIZED;
                playerRanking[client] = rank;

                // load the scoreboard
                loadPlayerScoreboard(client, scoreboard);

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
public void OnClientDisconnect(int client)
{
    // logging
    FormatEx(debugMessage, sizeof(debugMessage), "OnClientDisconnect triggered");
    printDebugMessage(client);

    // check if the player was playing
    if (playerActive[client] > 0 && mapStarted == true) {
        // logging
        PrintToChatAll("[ELO] %N did (rage) quit during active game, assining elo penalty");
        FormatEx(debugMessage, sizeof(debugMessage), "Player did ragequit");
        printDebugMessage(client);

        // player rq
        playerRageQuit[client] = 1;

        int groupElo = calculateGroupElo();
        updatePlayerElo(client, groupElo, false);
    }
}

/*****************************
 * Map related
 ****************************/

/**
  * Fetch the current map name
  */
public void OnMapStart()
{
    // logging
    FormatEx(debugMessage, sizeof(debugMessage), "OnMapStart triggered");
    printDebugMessage(UNKNOWN);

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
        FormatEx(query, sizeof(query), "SELECT score, retry_limit, id FROM map_score WHERE map_name = '%s' and challenge = '%s'", mapName, challenge);
        DBResultSet results = SQL_Query(db, query);

        PrintToServer("[ELO:db] %s", query);
        while (SQL_FetchRow(results)) {
            // params
            int dbEce = SQL_FetchInt(results, 0);
            int difficulty = currentDifficulty.IntValue;
            mapRetries = SQL_FetchInt(results, 1);
            mapId = SQL_FetchInt(results, 2);
            
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

            PrintToChatAll("[ELO] ranking enabled, map ece is %d with %d tries", mapEce, mapRetries);
        } else {
            PrintToChatAll("[ELO] unsupported map, difficulty or challenge, ranking is disabled.");
        }
    }

    disableReadyOverride();
}

public void disableReadyOverride()
{
    if (readyOverride.IntValue > 0) {
        readyOverride.SetInt(0);
    }
}

/**
  * Display ELO to players
  */
public void ShowPlayerElo(int client)
{
    CreateTimer(MAP_PRINT_DELAY + 0.2, PrintWelcomePlayer, client);
    CreateTimer(MAP_PRINT_DELAY + 1.0, PrintPlayerElo, client);
}

public Action PrintPlayerElo(Handle timer, int client)
{
    if (isValidPlayer(client)) {
        int elo = playerElo[client];
        int prevElo = playerPrevElo[client];

        if (elo == UNKNOWN || elo == UNINITIALIZED) {
            elo = DEFAULT_ELO;
        }

        if (prevElo == UNINITIALIZED || elo == prevElo || playerRetries[client] > 0) {
            if (playerRanking[client] == UNKNOWN) {
                PrintToChatAll("[ELO] %N has no ranking", client);
            } else {
                PrintToChatAll("[ELO] %N is ranked #%d and has %d elo", client, playerRanking[client], elo);
            }
        } else if (elo > prevElo) {
            PrintToChatAll("[ELO] %N has gained %d elo and has now %d", client, elo - prevElo, elo);
        } else {
            PrintToChatAll("[ELO] %N has lost %d elo and has now %d", client, prevElo - elo, elo);
        }
    }
}

public Action PrintWelcomePlayer(Handle timer, int client)
{
    if (isValidPlayer(client)) {
        int elo = playerElo[client]; 
        int prevElo = playerElo[client];

        if (prevElo == UNINITIALIZED || elo == prevElo) {
            PrintToChat(client, "[ELO] welcome %N. You joined a ranked server, ELO version is %s", client, VERSION);
        }
    }
}

/*****************************
 * Events
 ****************************/

public Action Event_Dispatcher(Event event, const char[] name, bool dontBroadcast)
{
    FormatEx(debugMessage, sizeof(debugMessage), "Event dispatched: %s", name);
    printDebugMessage(UNKNOWN);

    if (StrEqual(name, "marine_selected")) {
        return Event_OnMarineSelected(event);
    } else if (StrEqual(name, "player_fullyjoined")) {
        return Event_OnPlayerJoined(event);
    } else if (StrEqual(name, "mission_success")) {
        return Event_OnMapSuccess(event);
    } else if (StrEqual(name, "mission_failed") || StrEqual(name, "asw_mission_restart")) {
        return Event_OnMapFailed(event);
    } else if (StrEqual(name, "marine_hurt")) {
        return Event_OnMarineDamage(event);
    } else if (StrEqual(name, "player_heal") || StrEqual(name, "player_heal_target")) {
        return Event_OnHeal(event);
    } else if (StrEqual(name, "player_deploy_ammo")) {
        return Event_OnAmmoDeployed(event);
    } else if (StrEqual(name, "damage_amplifier_placed") || StrEqual(name, "heal_beacon_placed")) {
        return Event_OnStuffDeployed(event);
    } else if (StrEqual(name, "alien_died")) {
        return Event_OnAlienKilled(event);
    } else if (StrEqual(name, "marine_extinguished")) {
        return Event_OnMarineExtinguished(event);
    } else if (StrEqual(name, "marine_infested_cured")) {
        return Event_OnInfestionCure(event);
    } else if (StrEqual(name, "achievement_earned")) {
        return Event_OnAchievement(event);
    } else {
        FormatEx(debugMessage, sizeof(debugMessage), "Event not forwarded: %s", name);
    }

    return Plugin_Continue;
}


public void Event_OnSettingsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    // relay to map start
    OnMapStart();
}

public Action Event_OnPlayerJoined(Event event)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    
    if (!playerRanking[client]) {
        OnClientConnected(client);
    }
    ShowPlayerElo(client);

    return Plugin_Continue;
}

public Action Event_OnMarineSelected(Event event)
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

    if (numMarines == 0) {
        // check if he dselected marine, aka asw_afk but played
        if (playerActive[client] > numMarines && playerRetries[client] > 0) {
            // asw afk award
            int groupElo = calculateGroupElo();
            updatePlayerElo(client, groupElo, false);
            PrintToChatAll("[ELO] %N did afk during map retry, awarding elo penalty", client);            
        }
    } else if (numMarines == 1) {
        // mark the player as playing
        playerActive[client] = numMarines;

        // display what flesh just joined
        ShowPlayerElo(client);
    } else {
        PrintToChatAll("[ELO] %N is using bots, disabling elo rankings", client);
        mapStarted = false;
    }

    return Plugin_Continue;
}

public Action Event_OnMapRestart(Event event)
{
    // relay to map failed
    if (mapStarted) {
        return Event_OnMapFailed(event);
    } else {
        return Plugin_Continue;
    }
}

public Action Event_OnMapFailed(Event event)
{
    // group elo
    int groupElo = calculateGroupElo();

    if (mapStarted == true) {
        // raise fail scores only once every map 
        mapStarted = false;        
        bool mapChange = false;

        // iterate players
        teamRetries = 0;
        for (new i = 1; i <= MaxClients; i++) {            
            if (isActivePlayer(i)) {
                
                playerRetries[i]++;
                if (playerRetries[i] > teamRetries) {
                    teamRetries = playerRetries[i];
                }

                // store player scoreboard
                storePlayerScoreboard(i);

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
                if (isActivePlayer(i) && playerRetries[i] > 1) {
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

public Action Event_OnMapSuccess(Event event)
{
    // group elo
    int groupElo = calculateGroupElo();

    CreateTimer(MAP_PRINT_DELAY - 0.2, Print_OnMapSuccess);

    for (new i = 1; i <= MaxClients; i++) {
        
        // check if the player is still here
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
 * Mid game events
 ****************************/

public Action Event_OnMarineDamage(Event event)
{
    // find how much the marine is hurt
    float health = event.GetFloat("health");

    // marine
    int victim = event.GetInt("userid");
    int victimClient = GetClientOfUserId(victim);

    // find out who did this
    int attacker = event.GetInt("attacker");
    int client = GetClientOfUserId(attacker);

    // store attacker damage
    int damage = 1;
    if (playerHealthRemaining[client] > 0) {
        // we know exactly how much
        damage = RoundFloat(playerHealthRemaining[client] - health);
    }
    playerTeamDamageDone[client] += damage;
    playerHealthRemaining[client] = RoundFloat(health);

    if (playerHealthRemaining[client] == 0) {
        playerDied[victimClient] = 1;
        
        // check who did this
        if (victim == attacker) {
            // self inflicted
            playerSuicide[client] = 1;
        } else {
            playerTeamKills[client]++;
        }    
    }

    return Plugin_Continue;
}

public Action Event_OnHeal(Event event)
{
    // look who healed
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    playerTeamHeals[client]++;
    return Plugin_Continue;
}

public Action Event_OnAmmoDeployed(Event event)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    playerAmmoDeployments[client]++;
    return Plugin_Continue;
}

public Action Event_OnStuffDeployed(Event event)
{
    int client = event.GetInt("marine");
    if (isActivePlayer(client)) {
        playerBeaconsPlaced[client]++;
    }
    return Plugin_Continue;
}

public Action Event_OnAlienKilled(Event event)
{
    int client = event.GetInt("marine");
    if (isActivePlayer(client)) {
        playerAlienKills[client]++;
    }
    return Plugin_Continue;
}

public Action Event_OnFastReload(Event event)
{
    int client = event.GetInt("marine");
    if (isActivePlayer(client)) {
        int reloadSpree = event.GetInt("reloads");
        if (reloadSpree >= 5) {
            playerFastReloadExpert[client] = 1;
        }
    }
    return Plugin_Continue;
}

public Action Event_OnInfestionCure(Event event)
{
    int userid = event.GetInt("curer");
    int client = GetClientOfUserId(userid);
    playerTeamInfestedCures[client]++;
    return Plugin_Continue;
}

public Action Event_OnMarineExtinguished(Event event)
{
    int userid = event.GetInt("extinguisher");
    int client = GetClientOfUserId(userid);
    playerTeamExtinguishes[client]++;
    return Plugin_Continue;
}

public Action Event_OnAchievement(Event event)
{
    int client = event.GetInt("player");
    if (isActivePlayer(client)) {
        playerAchievementEarned[client]++;
    }
    return Plugin_Continue;
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

    // cleanup old shit
    cleanRankings();

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

public calculateGroupElo()
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
    FormatEx(query, sizeof(query), "UPDATE player_score set last_map = '%s' where steamid = %d", playerRetries[client], escapedMapName, playerSteamId[client]);
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
        FormatEx(query, sizeof(query), "INSERT INTO player_score (steamid, elo, version) values (%d, %d, '%s') ON DUPLICATE KEY UPDATE elo = %d, last_map = ''", steamid, elo, VERSION, elo);
        PrintToServer("[ELO:db] %s", query);
        db.Query(dbQuery, query, client);

        // store history
        int gain = elo - playerPrevElo[client];
        FormatEx(query, sizeof(query), "INSERT INTO player_history (steamid, elo, gain, map_challenge, difficulty, version) values (%d, %d, %d, %d, %d, '%s')", steamid, elo, gain, mapId, currentDifficulty.IntValue, VERSION);
        PrintToServer("[ELO:db] %s", query);
        db.Query(dbQuery, query, client);

        // reset scoreboard
        resetPlayerScoreboard(client);

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

public calculateElo(int client, int groupEloScore, bool success) 
{
    int currentElo = playerElo[client];
    float groupElo = groupEloScore + 0.0;

    float elo = currentElo + 0.0;
    float ece = mapEce + 0.0;

    // teamkills
    if (playerTeamKills[client] > 0) {
        ece = ece * 0.1 * playerTeamKills[client];
    }

    // suicide
    if (playerSuicide[client] > 0)  {
        ece -= ece * 0.2 * playerSuicide[client];
    }
    
    // team heals
    if (playerTeamHeals[client] > 0) {
        int healPoints = playerTeamHeals[client];
        if (healPoints > 100) {
            healPoints = 100;
        }
        ece += ece * 0.001 * healPoints;
    }

    // alien kills
    if (playerAlienKills[client] > 0) {
        int kills = playerAlienKills[client];
        if (kills > 100) {
            kills = 100;
        }

        ece += ece * 0.001 * kills;
    }

    // marine cures
    if (playerTeamInfestedCures[client] > 0) {
        ece += ece * 0.1 * playerTeamInfestedCures[client];
    }

    // achievements
    if (playerAchievementEarned[client] > 0) {
        ece += ece * 0.01 * playerAchievementEarned[client];
    }

    // extinguishes
    if (playerTeamExtinguishes[client] > 0) {
        ece += ece * 0.01 * playerTeamExtinguishes[client];
    }

    // support beacon bonus 
    if (playerBeaconsPlaced[client] > 0) {
        ece += ece * 0.01 * playerBeaconsPlaced[client];
    }

    // ammo deployment bonus, todo: detect if it was for others
    if (playerAmmoDeployments[client] > 0) {
        ece += ece * 0.01 * playerAmmoDeployments[client];
    }

    // marine played perfect
    if (playerTeamDamageDone[client] < 1 && playerAlienDamageTaken[client] < 1) {
        // perfect!
        ece += ece * 0.2;
    }

    // personal damage taken from swarm
    if (playerAlienDamageTaken[client] > 0) {
        ece -= ece * 0.001 * playerAlienDamageTaken[client]; 
    }

    // personal damage done to friendlies
    if (playerTeamDamageDone[client] > 0) {
        ece -= ece * 0.0001 * playerTeamDamageDone[client];
    }

    // ragequit award
    if (playerRageQuit[client] > 0) {
        ece -= ece * 0.3;
    }

    // do not calculate if client is uninitialized
    if (currentElo == UNINITIALIZED) {
        // reconnect the client
        OnClientConnected(client);
    } else if (ece != UNINITIALIZED) {
        // success
        if (success == true) {
            float gain = (ece - groupElo + OFFSET_ELO) / 10;
            if (gain <= 4.0) {
                elo = elo + 1.0;
            } else {
                elo = elo + 1.0 / (elo / groupElo) * gain;
            }
        } else {
            // failure
            float eloPenalty = (groupElo - ece + OFFSET_ELO) / 10;
            if (eloPenalty > 0.0) {
                elo = elo - (elo / groupElo) * eloPenalty;
            }
        }
    }

    return RoundFloat(elo);
}

public void cleanRankings()
{
    // cleanup old entries
    db.Query(dbQuery, "UPDATE player_score set last_map = NULL where updated_at < date_sub(now(), interval 1 hour)");
    db.Query(dbQuery, "DELETE FROM player_history where updated_at < date_sub(now(), interval 6 month)");

    // players loose elo if they (rage)quit with an active scoreboard, and never join back
    db.Query(dbQuery,"INSERT INTO player_history (steamid, elo, gain, scoreboard, version) SELECT steamid, elo * 0.90, 0 - elo * 0.10, '{ \"ragequit\": 1, \"score\": \"-10%\" }', version FROM player_score WHERE scoreboard IS NOT NULL AND scoreboard != '' AND updated_at < date_sub(now(), interval 4 hour)"
    );  
    db.Query(dbQuery, "UPDATE player_score set scoreboard = NULL, elo = elo * 0.90 where scoreboard IS NOT NULL AND scoreboard != '' AND updated_at < date_sub(now(), interval 4 hour)");

    // players loose elo after some time of inactivity, down to the initial elo of 1500
    db.Query(dbQuery,
        "INSERT INTO player_history (steamid, elo, gain, scoreboard, version) SELECT steamid, elo * 0.99, 0 - elo * 0.01, '{ \"inactivity\": 1, \"score\": \"-1%\" }', version FROM player_score WHERE elo >= 1200 * 0.01 and updated_at < date_sub(now(), interval 1 week)"
    );  
    db.Query(dbQuery, "UPDATE player_score set elo = elo * 0.99 where elo >= 1200 * 0.01 and updated_at < date_sub(now(), interval 1 week)");
}

public void printDebugMessage(int client)
{
    if (debugEnabled == true) {
        if (client != UNKNOWN && isValidPlayer(client)) {
            PrintToServer("[ELO:debug] %L: %s", client, debugMessage);
            PrintToChatAll("[ELO:debug] %L: %s", client, debugMessage);
        } else {
            PrintToServer("[ELO:debug] %s", debugMessage);
            PrintToChatAll("[ELO:debug] %s", debugMessage);
        }
    }
}

public void storePlayerScoreboard(int client)
{
    FormatEx(debugMessage, sizeof(debugMessage), "Store scoreboard");
    printDebugMessage(client);

    int steamid = playerSteamId[client];
    char scoreboard[1024];
    FormatEx(
        scoreboard, 
        sizeof(scoreboard), 
        "%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
        playerRetries[client],
        playerTeamKills[client],
        playerAlienDamageTaken[client],
        playerTeamDamageDone[client],
        playerSuicide[client],
        playerTeamHeals[client],
        playerAlienKills[client],
        playerTeamInfestedCures[client],
        playerFastReloadExpert[client],
        playerAchievementEarned[client],
        playerBeaconsPlaced[client],
        playerAmmoDeployments[client],
        playerTeamExtinguishes[client]
    );

    // store scoreboard
    char query[2048];
    FormatEx(
        query, 
        sizeof(query), 
        "UPDATE player_score set scoreboard = '%s' where steamid = %d", 
        scoreboard, 
        steamid
    );
    PrintToServer("[ELO:db] %s", query);
    db.Query(dbQuery, query, client);

    // store in history in json format as well
    FormatEx(
        scoreboard,
        sizeof(scoreboard),
        "{ \"playerRetries\": %d, \"playerTeamKills\": %d, \"playerAlienDamageTaken\": %d, \"playerTeamDamageDone\": %d, \"playerSuicide\": %d, \"playerTeamHeals\": %d, \"playerAlienKills\": %d,\"playerTeamInfestedCures\": %d, \"playerFastReloadExpert\": %d, \"playerAchievementEarned\": %d, \"playerBeaconsPlaced\": %d, \"playerAmmoDeployments\": %d, \"playerTeamExtinguishes\": %d }",
        playerRetries[client],
        playerTeamKills[client],
        playerAlienDamageTaken[client],
        playerTeamDamageDone[client],
        playerSuicide[client],
        playerTeamHeals[client],
        playerAlienKills[client],
        playerTeamInfestedCures[client],
        playerFastReloadExpert[client],
        playerAchievementEarned[client],
        playerBeaconsPlaced[client],
        playerAmmoDeployments[client],
        playerTeamExtinguishes[client]        
    );

    FormatEx(
        query, 
        sizeof(query), 
        "UPDATE player_history set scoreboard = '%s' where steamid = %d and scoreboard IS NULL AND updated_at > date_sub(now(), interval 1 hour) ORDER BY updated_at DESC LIMIT 1",
        scoreboard,
        steamid
    );
    PrintToServer("[ELO:db] %s", query);
    db.Query(dbQuery, query, client);
}

public void resetPlayerScoreboard(int client)
{
    FormatEx(debugMessage, sizeof(debugMessage), "Reset scoreboard");
    printDebugMessage(client);

    int steamid = playerSteamId[client];

    playerRetries[client] = 0;
    playerTeamKills[client] = 0;
    playerAlienDamageTaken[client] = 0;
    playerTeamDamageDone[client] = 0;
    playerSuicide[client] = 0;
    playerTeamHeals[client] = 0;
    playerAlienKills[client] = 0;
    playerTeamInfestedCures[client] = 0;
    playerFastReloadExpert[client] = 0;
    playerAchievementEarned[client] = 0;
    playerBeaconsPlaced[client] = 0;
    playerAmmoDeployments[client] = 0;
    playerTeamExtinguishes[client] = 0;

    playerDied[client] = 0;
    playerRageQuit[client] = 0;

    char query[128];
    FormatEx(query, sizeof(query), "UPDATE player_score set scoreboard = NULL where steamid = %d", steamid);
    PrintToServer("[ELO:db] %s", query);
    db.Query(dbQuery, query, client);
}

public int getVal(const char[][] buffer, int position)
{
    char value[8];
    FormatEx(value, sizeof(value), buffer[position]);
    FormatEx(debugMessage, sizeof(debugMessage), "Scoreboard position %d has value %s", position, value);

    return StringToInt(value);
}


public void loadPlayerScoreboard(int client, const char[] scoreboard)
{
    FormatEx(debugMessage, sizeof(debugMessage), "Loading scoreboard: %s", scoreboard);
    printDebugMessage(client);

    char buf[16][8];
    ExplodeString(scoreboard, ",", buf, sizeof(buf), 8);
 
    playerRetries[client] = getVal(buf, 0);
    playerTeamKills[client] = getVal(buf, 1);
    playerAlienDamageTaken[client] = getVal(buf, 2);
    playerTeamDamageDone[client] = getVal(buf, 3);
    playerSuicide[client] = getVal(buf, 4);
    playerTeamHeals[client] = getVal(buf, 5);
    playerAlienKills[client] = getVal(buf, 6);
    playerTeamInfestedCures[client] = getVal(buf, 7);
    playerFastReloadExpert[client] = getVal(buf, 8);
    playerAchievementEarned[client] = getVal(buf, 9);
    playerBeaconsPlaced[client] = getVal(buf, 10);
    playerAmmoDeployments[client] = getVal(buf, 11);
    playerTeamExtinguishes[client] = getVal(buf, 12);  

    FormatEx(debugMessage, sizeof(debugMessage), "Retry set at %d", playerRetries[client]); 
    printDebugMessage(client);

    FormatEx(debugMessage, sizeof(debugMessage), "Suicides set at %d", playerSuicide[client]); 
    printDebugMessage(client);
}
