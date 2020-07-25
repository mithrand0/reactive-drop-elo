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

#define VERSION "0.0.1"

/* Plugin Info */
public Plugin myinfo =
{
    name =          "AS:RD ELO`",
    author =        "jhheight",
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

Database hDatabase = null;
 
public void OnPluginStart()
{
    currentChallenge = FindConVar("rd_challenge");
    currentDifficulty = FindConVar("asw_skill");

    HookEvent("game_start", GameplayStart, EventHookMode_PostNoCopy);
    HookEvent("mission_success", MissionSuccess);
    HookEvent("mission_failed", MissionFailed);
}

/************************************/
// Database                 
/************************************/
public void ConnectDB()
{
    if (!hDatabase) {
        Database.Connect(GotDatabase);
    }
}

public void GotDatabase(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("ELO Database failure: %s", error);
    } 
    else 
    {
        delete db;
    }
}

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
    int steamid = GetSteamAccountID(client);
    char query[256];
    FormatEx(query, sizeof(query), "SELECT elo FROM users WHERE steamid = %d", steamid);
    hDatabase.Query(FetchPlayerElo, query, client);
}

public void FetchPlayerElo(Database db, DBResultSet results, const char[] error, any data)
{
    int client = 0;
    if ((client = GetClientOfUserId(data)) == 0) {
        // client disconnected
        return;
    }

    // fetch
    int result = FetchResult(db, results, error);
    if (result == 0) {
        result = 1000; // default elo
    }

    PlayerELOs[client] = result;
}

/************************************/
// Map starts, fetch the ECE
/************************************/
public Action:GameplayStart(Event event, const char[] name, bool dontBroadcast)
{
    TotalELO = 0;
    AverageGroupELO = 0.0;

    int players = 0;
    for (new i = 1; i <= MAXPLAYERS; i++)
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
public Action:MissionSuccess(Event event, const char[] name, bool dontBroadcast)
{
    for (new i = 1; i <= MAXPLAYERS; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            UpdateElo(i, true);
        }
    }
}

public Action:MissionFailed(Event event, const char[] name, bool dontBroadcast)
{
    for (new i = 1; i <= MAXPLAYERS; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            UpdateElo(i, false);
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
        if (LoseTotalELO <= 0) return;
        else 
        {
            NewELO = CurrentELO - (CurrentELO / AverageGroupELO) * LoseTotalELO;
        }
    }

    // write to the db
    int steamid = GetSteamAccountID(client);
    char query[1024];
    FormatEx(query, sizeof(query), "REPLACE INTO player_score (steamid, elo) values (%d, %d)", steamid, NewELO);
    hDatabase.Query(UpdateDBElo, query, client);

    PlayerELOs[client] = RoundFloat(NewELO);
}

public void UpdateDBElo(Database db, DBResultSet results, const char[] error, any data)
{
    // just verify we had no errors
    FetchResult(db, results, error);
}