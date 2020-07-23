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

bool ChallengeSupported = false;
int MapECE = 0;
int PlayerCount = -1;
int PlayerELOs[MAXPLAYERS+1];
int TotalELO = 0;
float AverageGroupELO = 0.0;

Database hDatabase = null;
 
public void OnPluginStart()
{
    HookEvent("game_start", GameplayStart, EventHookMode_PostNoCopy);
    HookEvent("mission_success", MissionSuccess);
    HookEvent("mission_failed", MissionFailed);
}

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

public void OnClientConnected(int client)
{
    ConnectDB();
    int steamid = GetSteamAccountID(client);

    char query[256];
    FormatEx(query, sizeof(query), "SELECT elo FROM users WHERE steamid = %d", steamid);
    hDatabase.Query(InitPlayerElo, query, client);
}

public void InitPlayerElo(Database db, DBResultSet results, const char[] error, any data)
{
    // -1 = not initialized
    int elo = -1;
    int client = 0;

    if ((client = GetClientOfUserId(data)) == 0) {
        // client disconnected
        return;
    }

    // check for errors
    if (db == null || results == null || error[0] != '\0')
    {
        // client is fucking around
        LogError("Query failed! %s", error);
    }
    else if (results.RowCount == 0)
    {
        // no elo for this player, award the default elo
        elo = 1000;
    }
    else
    {
        while (SQL_FetchRow(results))
        {
            elo = SQL_FetchInt(results, 0);
            PrintToServer("Elo %d was loaded for player %s", elo);
        }
    }

    PlayerELOs[client] = elo;
}


void CheckChallengeSupported()
{
    char ChallengeName[128];

    ConVar rd_challenge = FindConVar("rd_challenge");
    rd_challenge.GetString(ChallengeName, sizeof(ChallengeName));
    
    if (StrEqual(ChallengeName, "ASBI Ranked"))
    {
        MapECE = GetMapECEASBI();
        ChallengeSupported = true;
    }
    else if (StrEqual(ChallengeName, "Vanilla Ranked"))
    {
        MapECE = GetMapECEVanilla();
        ChallengeSupported = true;
    }
    else
    {
        ChallengeSupported = false;
        // need to say in chat that challenge not supported by the plugin and also cancel other function executions ideally
    }
}

public Action:GameplayStart(Event event, const char[] name, bool dontBroadcast)
{
    TotalELO = 0;
    AverageGroupELO = 0.0;

    CheckChallengeSupported();
    if(ChallengeSupported)
    {
        int i = 0;
        int players = 0;
        for (i = 1; i <= MAXPLAYERS; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i)) {
                TotalELO += PlayerELOs[i];
                players++;
                /*
                    todo:
                    save players' userid and elo in 2 global arrays which will be used in either mission success or mission failed functions.
                */
            }
        }
        PlayerCount = players;

        AverageGroupELO = (TotalELO + 0.0) / PlayerCount;
        // type MapECE and AverageGroupELO in chat about a second after gameplaystart
    }
}

public Action:MissionSuccess(Event event, const char[] name, bool dontBroadcast)
{
    if (ChallengeSupported)
    {
        int i = 0;
        for (i = 1; i <= MAXPLAYERS; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i)) {
                EloChanger(true, PlayerELOs[i]);
                WriteDatabase();
            }
        }
    }
}

public Action:MissionFailed(Event event, const char[] name, bool dontBroadcast)
{
 if (ChallengeSupported)
    {
        int i = 0;
        for (i = 1; i <= MAXPLAYERS; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i)) {
                EloChanger(false, PlayerELOs[i]);
                WriteDatabase();
            }
        }
    }
}

void WriteDatabase()
{
    // write steamid64 + elo player ranking to database
}

int GetMapECEVanilla()
{
    char map[128];

    switch(map)
    {
        case "asi-jac1-landingbay_01":
            return 1200;
        case "asi-jac1-landingbay_02":
            return 1300;
        case "asi-jac2-deima":
            return 1000;
        case "asi-jac3-rydberg":
            return 1400;
        case "asi-jac4-residential":
            return 1600;
        case "asi-jac6-sewerjunction":
            return 1000;
        case "asi-jac7-timorstation":
            return 1500;
        case "rd-area9800lz":
            return 1500;
        case "rd-area9800pp1":
            return 1400;
        case "rd-area9800pp2":
            return 1300;
        case "rd-area9800wl":
            return 1300;
        case "rd-lan1_bridge":
            return 1750;
        case "rd-lan2_sewer":
            return 1400;
        case "rd-lan3_maintenance":
            return 1650;
        case "rd-lan4_vent":
            return 1400;
        case "rd-lan5_complex":
            return 1350;
        case "rd-ocs1storagefacility":
            return 900;
        case "rd-ocs2landingbay7":
            return 1050;
        case "rd-ocs3uscmedusa":
            return 1100;
        case "rd-par1unexpected_encounter":
            return 1350;
        case "rd-par2hostile_places":
            return 1250;
        case "rd-par3close_contact":
            return 1400;
        case "rd-par4high_tension":
            return 1800;
        case "rd-par5crucial_point":
            return 1300;
        case "rd-res1forestentrance":
            return 1200;
        case "rd-res2research7":
            return 1200;
        case "rd-res3miningcamp":
            return 1450;
        case "rd-res4mines":
            return 1350;
        case "rd-tft1desertoutpost":
            return 1750;
        case "rd-tft2abandonedmaintenance":
            return 1300;
        case "rd-tft3spaceport":
            return 1600;
        case "rd-til1midnightport":
            return 1650;
        case "rd-til2roadtodawn":
            return 1350;
        case "rd-til3arcticinfiltration":
            return 1350;
        case "rd-til4area9800":
            return 1450;
        case "rd-til5coldcatwalks":
            return 1400;
        case "rd-til6yanaurusmine":
            return 1400;
        case "rd-til7factory":
            return 1500;
        case "rd-til8comcenter":
            return 1450;
        case "rd-til9syntekhospital":
            return 1500;
        case "rd-bonus_mission1":
            return 1500;
        case "rd-bonus_mission2":
            return 1400;
        case "rd-bonus_mission3":
            return 1600;
        case "rd-bonus_mission4":
            return 1650;
        case "rd-bonus_mission5":
            return 1700;
        case "rd-bonus_mission6":
            return 1750;
        case "rd-bonus_mission7":
            return 1850;
        default:    // need create a check if mapece > 0 in main
            return -1;
    }
}

int GetMapECEASBI()
{
    char map[128];
    map = "TODO: detect";
    
    // switch(map)
    // {
    //     case "asi-jac1-landingbay_01":
    //         return 1900;
    //     case "asi-jac1-landingbay_02":
    //         return 1850;
    //     case "asi-jac2-deima":
    //         return 1700;
    //     case "asi-jac3-rydberg":
    //         return 2000;
    //     case "asi-jac4-residential":
    //         return 2300;
    //     case "asi-jac6-sewerjunction":
    //         return 1900;
    //     case "asi-jac7-timorstation":
    //         return 2050;
    //     case "rd-area9800lz":
    //         return 2100;
    //     case "rd-area9800pp1":
    //         return 1900;
    //     case "rd-area9800pp2":
    //         return 1800;
    //     case "rd-area9800wl":
    //         return 2000;
    //     case "rd-lan1_bridge":
    //         return 2400;
    //     case "rd-lan2_sewer":
    //         return 2050;
    //     case "rd-lan3_maintenance":
    //         return 2150;
    //     case "rd-lan4_vent":
    //         return 1900;
    //     case "rd-lan5_complex":
    //         return 1900;
    //     case "rd-ocs1storagefacility":
    //         return 1500;
    //     case "rd-ocs2landingbay7":
    //         return 1800;
    //     case "rd-ocs3uscmedusa":
    //         return 1750;
    //     case "rd-par1unexpected_encounter":
    //         return 2050;
    //     case "rd-par2hostile_places":
    //         return 2000;
    //     case "rd-par3close_contact":
    //         return 2100;
    //     case "rd-par4high_tension":
    //         return 2500;
    //     case "rd-par5crucial_point":
    //         return 2050;
    //     case "rd-res1forestentrance":
    //         return 1950;
    //     case "rd-res2research7":
    //         return 1900;
    //     case "rd-res3miningcamp":
    //         return 2150;
    //     case "rd-res4mines":
    //         return 2150;
    //     case "rd-tft1desertoutpost":
    //         return 2400;
    //     case "rd-tft2abandonedmaintenance":
    //         return 1900;
    //     case "rd-tft3spaceport":
    //         return 2300;
    //     case "rd-til1midnightport":
    //         return 2250;
    //     case "rd-til2roadtodawn":
    //         return 1950;
    //     case "rd-til3arcticinfiltration":
    //         return 1900;
    //     case "rd-til4area9800":
    //         return 2050;
    //     case "rd-til5coldcatwalks":
    //         return 2100;
    //     case "rd-til6yanaurusmine":
    //         return 2000;
    //     case "rd-til7factory":
    //         return 2100;
    //     case "rd-til8comcenter":
    //         return 2100;
    //     case "rd-til9syntekhospital":
    //         return 2150;
    //     case "rd-bonus_mission1":
    //         return 2000;
    //     case "rd-bonus_mission2":
    //         return 1900;
    //     case "rd-bonus_mission3":
    //         return 2200;
    //     case "rd-bonus_mission4":
    //         return 2450;
    //     case "rd-bonus_mission5":
    //         return 2700;
    //     case "rd-bonus_mission6":
    //         return 2700;
    //     case "rd-bonus_mission7":
    //         return 2800;
    //     default:    // need create a check if mapece > 0 in main
            return -1;
    // }
}

void EloChanger(bool MatchCondition, int CurrentELO)    // elo calculator
{
    if (MatchCondition)    // if the team succeeded in completing the map
    {
        float GainTotalELO = (MapECE - AverageGroupELO + 600) / 10;
        if (GainTotalELO <= 4)
        {
            CurrentELO++;
            return;
        }
        else 
        {
            CurrentELO += 1 / (CurrentELO / AverageGroupELO) * GainTotalELO;
        }
    }
    else    // if the team did not succeed
    {
        float LoseTotalELO = (AverageGroupELO - MapECE + 600) / 10;
        if (LoseTotalELO <= 0) return;
        else 
        {
            CurrentELO -= (CurrentELO / AverageGroupELO) * LoseTotalELO;
        }
    }
}
