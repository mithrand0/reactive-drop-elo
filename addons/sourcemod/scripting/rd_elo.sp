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
    author =        "jhheight, Mithrand",
    description =   "ELO module for Reactive Drop",
    url =           "https://github.com/mithrand0",
    version =       VERSION
};

int MapECE = 0;
char currentMap[256];
ConVar currentChallenge;
ConVar currentDifficulty;
int PlayerCount = -1;
int PlayerELOs[MAXPLAYERS+1];
int TotalELO = 0;
float AverageGroupELO = 0.0;


bool enableDb = false;
Database hDatabase;

new String:test_events[][] = { 
    "game_init", 
    "asw_mission_restart",
    "alien_died", 
    "marine_selected",
    "difficulty_changed",
    "mission_success",
    "mission_failed",
    "button_area_active"
};
 
public void OnPluginStart()
{
    PrintToServer("[ELO] connecting to db");

    char dbError[256];
    if (enableDb) {
        hDatabase = SQL_Connect("elo", true, dbError, sizeof(dbError));

        if (hDatabase == null) {
            PrintToServer(dbError);
        }
    }
    
    PrintToServer("[ELO] hooking convars");
    currentChallenge = FindConVar("rd_challenge");
    currentDifficulty = FindConVar("asw_skill");

    PrintToServer("[ELO] ELO ranking initing");

    // init clients
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            OnClientConnected(i);
        }
    }

    PrintToServer("[ELO] mass hooking events");
    bool eventHookLoaded;

    for (new v=0; v<sizeof(test_events); v++) {
        eventHookLoaded = HookEventEx(test_events[v], Event_Test, EventHookMode_Pre);
        if (eventHookLoaded) {
            PrintToServer("[HOOK] Eventhook loader: %s", test_events[v]);
        } else {
            PrintToServer("[HOOK FAILED] Eventhook failed: %s", test_events[v]);
        }
    }
}

public Action Event_Test(Event event, const char[] name, bool dontBroadcast)
{
    PrintToServer("[EVENT TRIGGERED] Event: %s", name);
    return Plugin_Continue;
}

/************************************/
// Database                 
/************************************/
public int FetchResult(Database db, DBResultSet results, const char[] error)
{
    int value = 0;

    // check for errors
    if (db == null || results == null || error[0] != '\0') {
        // client is fucking around
        LogError("Query failed! %s", error);
        value = -1;
    } else {
        while (SQL_FetchRow(results))
        {
            value = SQL_FetchInt(results, 0);
            PrintToServer("Value %d was loaded", value);
        }
    }

    return value;
}


/************************************/
// Client connects, fetch his elo
/************************************/
public void OnClientConnected(int client)
{
    PrintToServer("[ELO] fetching client ELO");

    int steamid = GetSteamAccountID(client);
    char query[256];
    FormatEx(query, sizeof(query), "SELECT elo FROM player_score WHERE steamid = %d", steamid);

    if (enableDb) {
        hDatabase.Query(FetchPlayerElo, query, client);
    } else {
        // XXX: test elo
        PlayerELOs[client] = 0;
    }
}

public void FetchPlayerElo(Database db, DBResultSet results, const char[] error, int client)
{
    PrintToServer("[ELO] Client elo fetched");

    // fetch
    int result = FetchResult(db, results, error);
    if (result == 0) {
        result = 1000; // default elo
        PrintToServer("[ELO] Assigning default elo");
    } else {
        PrintToServer("[ELO] Assigned elo %d", result);
    }

    PlayerELOs[client] = result;
}

/************************************/
// Map starts, fetch the ECE
/************************************/
public void OnMapStart()
{
    PrintToServer("[ELO] starting map");

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

    char challenge[128];
    currentChallenge.GetString(challenge, sizeof(challenge));

    // fetch map elo in the background
    char query[256];
    FormatEx(
        query,
        sizeof(query), 
        "SELECT score FROM map_score WHERE map_name = '%s' and difficulty = %d and challenge = '%s'", 
        currentMap,
        currentDifficulty.IntValue,
        challenge
    );

    hDatabase.Query(FetchMapECE, query);
}

public void FetchMapECE(Database db, DBResultSet results, const char[] error, any data)
{
    // by default, we have no reward
    MapECE = FetchResult(db, results, error);
}

/************************************/
// Map finished, recalculate elo's
/************************************/
public Action Event_OnMapFailure(Event event, const char[] name, bool dontBroadcast)
{
    UpdatePlayerElos(false);
    return Plugin_Continue;
}

public Action Event_OnMapSuccess(Event event, const char[] name, bool dontBroadcast)
{
    UpdatePlayerElos(true);
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
public int UpdateElo(int client, bool success)
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

    // write to the db
    int steamid = GetSteamAccountID(client);
    char query[1024];
    FormatEx(query, sizeof(query), "REPLACE INTO player_score (steamid, elo) values (%d, %d)", steamid, NewELO);

    if (enableDb) {
        hDatabase.Query(UpdateDBElo, query, client);
    }

    PlayerELOs[client] = RoundFloat(NewELO);
}

public void UpdateDBElo(Database db, DBResultSet results, const char[] error, any data)
{
    // just verify we had no errors
    FetchResult(db, results, error);
}