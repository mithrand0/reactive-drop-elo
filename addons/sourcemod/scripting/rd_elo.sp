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
    name =          "AS:RD ELO`",
    author =        "Mithrand, jhheight",
    description =   "ELO module for Reactive Drop",
    url =           "https://github.com/mithrand0",
    version =       VERSION
};

/* don't punish players for restarting mission when in lobby or restarting without completing a single objective & in first 30 seconds of gameplaystart */
bool MissionFailed = false;
int MapECE = 0;
char currentMap[256];
ConVar currentChallenge;
ConVar currentDifficulty;
int oldDifficulty;
char oldChallenge[128];
int PlayerCount = -1;
int PlayerELOs[MAXPLAYERS+1];
int TotalELO = 0;
int RetryAmt = 0;
float AverageGroupELO = 0.0;


bool enableDb = true;
Database hDatabase;

new String:test_events[][] = { 
    "game_init", 
    "asw_mission_restart",
    "difficulty_changed",
    "mission_success",
    "mission_failed"
};
 
public void OnPluginStart()
{
    char dbError[256];
    if (enableDb) {
        PrintToServer("[ELO:DB] connecting to database..");
        hDatabase = SQL_Connect("elo", true, dbError, sizeof(dbError));

        if (hDatabase == null) {
            PrintToServer("[ELO] error: %s", dbError);
        } else {
            PrintToServer("[ELO:DB] connected");
        }

    }
    
    PrintToServer("[ELO:hooks] hooking convars");
    currentChallenge = FindConVar("rd_challenge");
    currentDifficulty = FindConVar("asw_skill");
    oldDifficulty = currentDifficulty.IntValue;
    currentChallenge.GetString(oldChallenge, sizeof(oldChallenge)); 

    // init clients
    PrintToServer("[ELO:init] iterating players");
    for (new i = 1; i <= MaxClients; i++)
    {
        PlayerELOs[i] = 0;
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            OnClientConnected(i);
        }
    }

    PrintToServer("[ELO:hooks] hooking events");
    HookEvent("mission_success", Event_OnMapSuccess, EventHookMode_Pre);
    HookEvent("mission_failed", Event_OnMapFailure, EventHookMode_Pre);
    HookEvent("difficulty_changed", Event_DifficultyChanged, EventHookMode_Pre);
    HookEvent("asw_mission_restart", Event_OnMissionRestart, EventHookMode_Pre);

    PrintToServer("[ELO:debug] hooking test events");
    bool eventHookLoaded;

    // XXX: event debugger
    for (new v=0; v<sizeof(test_events); v++) {
        eventHookLoaded = HookEventEx(test_events[v], Event_Test, EventHookMode_Pre);
        if (eventHookLoaded) {
            PrintToServer("[ELO:debug] eventhook loaded: %s", test_events[v]);
        } else {
            PrintToServer("[ELO:debug] FAILURE: eventhook failed: %s", test_events[v]);
        }
    }
}

public Action Event_Test(Event event, const char[] name, bool dontBroadcast)
{
    PrintToServer("[ELO:debug] event fired: %s", name);
    return Plugin_Continue;
}

/************************************/
// Database                 
/************************************/
public int FetchResult(Database db, DBResultSet results, const char[] error)
{
    int value = 0;
    PrintToServer("[ELO:fetch] default score assigned: %d", value);

    // check for errors
    if (db == null || results == null || error[0] != '\0') {
        // client is fucking around
        PrintToServer("[ELO:fetch] failed: %s", error);
        value = -1;
    } else {
        while (SQL_FetchRow(results))
        {
            value = SQL_FetchInt(results, 0);
            PrintToServer("[ELO:fetch] score assigned: %d", value);
        }
    }

    return value;
}


/************************************/
// Client connects, fetch his elo
/************************************/
public void OnClientConnected(int client)
{
    // only init when we have no elo score yet
    if (PlayerELOs[client] == 0) {
        int steamid = GetSteamAccountID(client);
        PrintToServer("[ELO:fetch] searching for steamid: %d", steamid);

        char query[256];
        FormatEx(query, sizeof(query), "SELECT elo FROM player_score WHERE steamid = %d", steamid);
        PrintToServer("[ELO:query] %s", query);

        if (enableDb) {
            hDatabase.Query(FetchPlayerElo, query, client);
        } else {
            // XXX: test elo
            PlayerELOs[client] = GetRandomInt(800, 1200);
            PrintToServer("[ELO:db] database is disabled, simulating random score: %d", PlayerELOs[client]);
        }
    } else {
        PrintToServer("[ELO:client] Client has elo an elo already: %d", PlayerELOs[client]);
    }
}

public void OnClientDisconnect(client)
{
    PlayerELOs[client] = 0;
}

public void FetchPlayerElo(Database db, DBResultSet results, const char[] error, int client)
{
    PrintToServer("[ELO:fetch-result] client elo fetched");

    // fetch
    int result = FetchResult(db, results, error);
    if (result == 0) {
        result = 1000; // default elo
        PrintToServer("[ELO:fetch-result] Assigning default elo");
    } else {
        PrintToServer("[ELO:fetch-result] Assigned elo %d", result);
    }

    PlayerELOs[client] = result;
}

/************************************/
// Map starts, fetch the ECE
/************************************/
public void OnMapStart()
{
    PrintToServer("[ELO:event] starting map");

    TotalELO = 0;
    AverageGroupELO = 0.0;

    int players = 0;
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            TotalELO += PlayerELOs[i];
            players++;
        }
    }

    PlayerCount = players;
    AverageGroupELO = (TotalELO + 0.0) / PlayerCount;

    // fetch current map
    GetCurrentMap(currentMap, sizeof(currentMap));

    PrintToServer("[RD:event] map: %s", currentMap);
}

public Action Event_DifficultyChanged(Event event, const char[] name, bool dontBroadcast)
{
    char newChallenge[128];
    currentChallenge.GetString(newChallenge, sizeof(newChallenge));
    // DEBUG: (currently should be working though)
    // PrintToServer("[RD:event] oldChallenge: %s", oldChallenge);
    // PrintToServer("[RD:event] oldDifficulty: %d", oldDifficulty);
    if (oldDifficulty != currentDifficulty.IntValue || strcmp(oldChallenge, newChallenge, true) != 0)    // for some reason when you press the challenge button this event is fired twice instantly, this IF should prevent that spam
    {
        PrintToServer("[RD:event] challenge: %s", newChallenge);
        PrintToServer("[RD:event] difficulty: %d", currentDifficulty.IntValue);
        currentChallenge.GetString(oldChallenge, sizeof(oldChallenge));
        oldDifficulty = currentDifficulty.IntValue;
        // fetch map elo in the background
        char query[256];
        FormatEx(
            query,
            sizeof(query), 
            "SELECT score FROM map_score WHERE map_name = '%s' and challenge = '%s'", 
            currentMap,
            oldDifficulty,
            newChallenge
        );

        hDatabase.Query(FetchMapECE, query);
    }
    return Plugin_Continue;
}

public void FetchMapECE(Database db, DBResultSet results, const char[] error, any data)
{
    // by default, we have no reward
    MapECE = FetchResult(db, results, error);
    if (MapECE > 0) 
    {
        PrintToChatAll("[RD:ELO] Current map ECE: %d", MapECE);
    }
    else
    {
        PrintToChatAll("[RD:ELO] Map or Challenge not recognised, ELO isn't counted.");
    }
}

public Action Event_OnMissionRestart(Event event, const char[] name, bool dontBroadcast)
{
    if (MissionFailed) {
        RetryAmt++;
    }
    MissionFailed = false;
    return Plugin_Continue;
}

/************************************/
// Map finished, recalculate elo's
/************************************/
public Action Event_OnMapFailure(Event event, const char[] name, bool dontBroadcast)
{
    MissionFailed = true;
    if (RetryAmt >= 2)   // max 2 retries per map, which means in total 3 tries.
    {
        PrintToServer("[ELO:event] Calculating map failed score");
        PrintToChatAll("[ELO:event] You have failed to complete the map.");
        UpdatePlayerElos(false);
        // TODO: type players' lost elo in chat, change to a random map after 8 seconds or so.
        RetryAmt = 0;
    }
    else 
    {
        PrintToChatAll("[ELO:event] Fail count: %d", 1 + RetryAmt);
        PrintToChatAll("[ELO:event] Tries left: %d", 2 - RetryAmt);
    }
    return Plugin_Continue;
}

public Action Event_OnMapSuccess(Event event, const char[] name, bool dontBroadcast)
{
    PrintToServer("[ELO:event] Calculating map success score");
    PrintToChatAll("[ELO:event] You have succeeded in completing the map.");
    UpdatePlayerElos(true);
    // TODO: type players' gained elo in chat, change to a random map after 8 seconds or so.
    RetryAmt = 0;
    return Plugin_Continue;
}

public void UpdatePlayerElos(bool success)
{
    for (new i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            UpdateElo(i, success);
        }
    }    
}

 // elo calculator
public void UpdateElo(int client, bool success)
{
    // TODO: jh needs to make this work
    // int elo = calculatePlayerElo(client, success);

    // XXX: debug to test it's working
    int elo = GetRandomInt(0, 666);
    int steamid = GetSteamAccountID(client);

    PrintToServer("[ELO:db] writing to DB");
    PrintToServer("[ELO:db] steamid: %d", steamid);
    PrintToServer("[ELO:db] elo: %d", elo);
    
    // write to the db
    char query[1024];
    FormatEx(query, sizeof(query), "REPLACE INTO player_score (steamid, elo) values (%d, %d)", steamid, elo);
    PrintToServer("[ELO:query] %s", query);

    if (enableDb) {
        hDatabase.Query(UpdateDBElo, query, client);
    }

    PlayerELOs[client] = elo;
}

public void UpdateDBElo(Database db, DBResultSet results, const char[] error, any data)
{
    // just verify we had no errors
    FetchResult(db, results, error);
    PrintToServer("[ELO:db] writing to DB done");
}

public int calculatePlayerElo(int client, bool success)
{
    int CurrentELO = PlayerELOs[client];
    float NewELO = CurrentELO + 0.0;

    if (success)    // if the team succeeded in completing the map
    {
        float GainTotalELO = (MapECE - AverageGroupELO + 600) / 10;
        if (GainTotalELO <= 4)
        {
            NewELO = CurrentELO + 1.0;
        }
        else 
        {
            NewELO = CurrentELO + 1.0 / (CurrentELO / AverageGroupELO) * GainTotalELO;
        }
    }
    else    // if the team did not succeed
    {
        float LoseTotalELO = (AverageGroupELO - MapECE + 600) / 10;
        if (LoseTotalELO > 0)
        {
            NewELO = CurrentELO - (CurrentELO / AverageGroupELO) * LoseTotalELO;
        }
    }

    return RoundFloat(NewELO);
}
