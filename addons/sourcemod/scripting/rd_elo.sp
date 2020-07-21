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

public void OnPluginStart()
{

}

int GetMapECEVanilla()
{
	char map[] = GetMapName().tolower();
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
			return 1700;
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
		default:	// need create a check if mapece > 0 in main
			return -1;
	}
}

int GetMapECEASBI()
{
	char map[] = GetMapName().tolower();
	switch(map)
	{
		case "asi-jac1-landingbay_01":
			return 1900;
		case "asi-jac1-landingbay_02":
			return 1850;
		case "asi-jac2-deima":
			return 1700;
		case "asi-jac3-rydberg":
			return 2000;
		case "asi-jac4-residential":
			return 2300;
		case "asi-jac6-sewerjunction":
			return 1900;
		case "asi-jac7-timorstation":
			return 2050;
		case "rd-area9800lz":
			return 2100;
		case "rd-area9800pp1":
			return 1900;
		case "rd-area9800pp2":
			return 1800;
		case "rd-area9800wl":
			return 2000;
		case "rd-lan1_bridge":
			return 2400;
		case "rd-lan2_sewer":
			return 2050;
		case "rd-lan3_maintenance":
			return 2150;
		case "rd-lan4_vent":
			return 1900;
		case "rd-lan5_complex":
			return 1900;
		case "rd-ocs1storagefacility":
			return 1500;
		case "rd-ocs2landingbay7":
			return 1800;
		case "rd-ocs3uscmedusa":
			return 1750;
		case "rd-par1unexpected_encounter":
			return 2050;
		case "rd-par2hostile_places":
			return 2000;
		case "rd-par3close_contact":
			return 2100;
		case "rd-par4high_tension":
			return 2500;
		case "rd-par5crucial_point":
			return 2050;
		case "rd-res1forestentrance":
			return 1950;
		case "rd-res2research7":
			return 1900;
		case "rd-res3miningcamp":
			return 2150;
		case "rd-res4mines":
			return 2150;
		case "rd-tft1desertoutpost":
			return 2400;
		case "rd-tft2abandonedmaintenance":
			return 1900;
		case "rd-tft3spaceport":
			return 2300;
		case "rd-til1midnightport":
			return 2250;
		case "rd-til2roadtodawn":
			return 1950;
		case "rd-til3arcticinfiltration":
			return 1900;
		case "rd-til4area9800":
			return 2050;
		case "rd-til5coldcatwalks":
			return 2100;
		case "rd-til6yanaurusmine":
			return 2000;
		case "rd-til7factory":
			return 2100;
		case "rd-til8comcenter":
			return 2100;
		case "rd-til9syntekhospital":
			return 2150;
		case "rd-bonus_mission1":
			return 2000;
		case "rd-bonus_mission2":
			return 1900;
		case "rd-bonus_mission3":
			return 2200;
		case "rd-bonus_mission4":
			return 2450;
		case "rd-bonus_mission5":
			return 2700;
		case "rd-bonus_mission6":
			return 2700;
		case "rd-bonus_mission7":
			return 2800;
		default:	// need create a check if mapece > 0 in main
			return -1;
	}
}

int EloChanger(bool MatchCondition, float CurrentELO, float AverageGroupELO, int MapECE)
{
	if (MatchCondition)	// if the team succeeded in completing the map
	{
		float GainTotalELO = (MapECE - AverageGroupELO + 600) / 10;
		if (GainTotalELO <= 4) return 1;
		else 
		{
			//float GainELO = pow((CurrentELO / (PlayerCount * AverageGroupELO) - 1),6) * pow(GainTotalELO,1.25);
			float GainELO = 1 / (CurrentELO / AverageGroupELO) * GainTotalELO; 
			return GainELO;
		}
	}
	else	// if the team did not succeed
	{
		float LoseTotalELO = (AverageGroupELO - MapECE + 600) / 10;
		if (LoseTotalELO <= 0) return 0;
		else 
		{
			//float LoseELO = -pow((CurrentELO / (PlayerCount * AverageGroupELO)),3) * pow(LoseTotalELO,1.8);
			float LoseELO = (CurrentELO / AverageGroupELO) * LoseTotalELO;
			return -LoseELO;
		}
	}
}
