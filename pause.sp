/*
	SourcePawn is Copyright (C) 2006-2008 AlliedModders LLC.  All rights reserved.
	SourceMod is Copyright (C) 2006-2008 AlliedModders LLC.  All rights reserved.
	Pawn and SMALL are Copyright (C) 1997-2008 ITB CompuPhase.
	Source is Copyright (C) Valve Corporation.
	All trademarks are property of their respective owners.

	This program is free software: you can redistribute it and/or modify it
	under the terms of the GNU General Public License as published by the
	Free Software Foundation, either version 3 of the License, or (at your
	option) any later version.

	This program is distributed in the hope that it will be useful, but
	WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
	General Public License for more details.

	You should have received a copy of the GNU General Public License along
	with this program.  If not, see <http://www.gnu.org/licenses/>.
*/
#pragma semicolon 1

#include <sourcemod>
#include <colors>
#include <sdktools>
#undef REQUIRE_PLUGIN
#include <readyup>

public Plugin:myinfo =
{
	name = "Pause plugin",
	author = "CanadaRox",
	description = "Adds pause functionality without breaking pauses",
	version = "9",
	url = ""
};

enum L4D2Team
{
	L4D2Team_None = 0,
	L4D2Team_Spectator,
	L4D2Team_Survivor,
	L4D2Team_Infected
}

new String:teamString[L4D2Team][] =
{
	"None",
	"Spectator",
	"Survivors",
	"Infected"
};

new Handle:Duration;
new Handle:menuPanel;
new Handle:readyCountdownTimer;
new Handle:sv_pausable;
new Handle:sv_noclipduringpause;
new bool:adminPause;
new bool:isPaused;
new bool:teamReady[L4D2Team];
new readyDelay;
new Handle:pauseDelayCvar;
new pauseDelay;
new bool:readyUpIsAvailable;
new Handle:pauseForward;
new Handle:unpauseForward;
new Handle:deferredPauseTimer;
new Handle:l4d_ready_delay;
new Handle:l4d_ready_blips;
new bool:playerCantPause[MAXPLAYERS+1];
new Handle:playerCantPauseTimers[MAXPLAYERS+1];
new bool:hiddenPanel[MAXPLAYERS + 1];
int tg;
int numb;

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	CreateNative("IsInPause", Native_IsInPause);
	pauseForward = CreateGlobalForward("OnPause", ET_Event);
	unpauseForward = CreateGlobalForward("OnUnpause", ET_Event);
	RegPluginLibrary("pause");

	MarkNativeAsOptional("IsInReady");
	return APLRes_Success;
}

public OnPluginStart()
{
	RegConsoleCmd("sm_hide", Hide_Cmd, "Hide team status panel");
	RegConsoleCmd("sm_show", Show_Cmd, "Show team status panel");
	RegConsoleCmd("sm_pause", Pause_Cmd, "Pauses the game");
	RegConsoleCmd("sm_unpause", Unpause_Cmd, "Marks your team as ready for an unpause");
	RegConsoleCmd("sm_ready", Unpause_Cmd, "Marks your team as ready for an unpause");
	RegConsoleCmd("sm_r", Unpause_Cmd, "Marks your team as ready for an unpause");
	RegConsoleCmd("sm_nr", Unready_Cmd, "Marks your team as ready for an unpause");
	RegConsoleCmd("sm_unready", Unready_Cmd, "Marks your team as ready for an unpause");
	RegConsoleCmd("sm_toggleready", ToggleReady_Cmd, "Toggles your team's ready status");

	RegAdminCmd("sm_forcepause", ForcePause_Cmd, ADMFLAG_BAN, "Pauses the game and only allows admins to unpause");
	RegAdminCmd("sm_forceunpause", ForceUnpause_Cmd, ADMFLAG_BAN, "Unpauses the game regardless of team ready status.  Must be used to unpause admin pauses");

	AddCommandListener(Say_Callback, "say");
	AddCommandListener(TeamSay_Callback, "say_team");
	AddCommandListener(Unpause_Callback, "unpause");

	sv_pausable = FindConVar("sv_pausable");
	sv_noclipduringpause = FindConVar("sv_noclipduringpause");

	pauseDelayCvar = CreateConVar("sm_pausedelay", "0", "Delay to apply before a pause happens.  Could be used to prevent Tactical Pauses", FCVAR_PLUGIN, true, 0.0);
	l4d_ready_delay = CreateConVar("l4d_ready_delay", "3", "Number of seconds to count down before the round goes live.", FCVAR_PLUGIN, true, 0.0);
	l4d_ready_blips = CreateConVar("l4d_ready_blips", "1", "Enable beep on unpause");
	
	HookEvent("round_end", RoundEnd_Event, EventHookMode_PostNoCopy);
	HookEvent("player_team", PlayerTeam_Event);
}

public OnAllPluginsLoaded()
{
	readyUpIsAvailable = LibraryExists("readyup");
}

public OnLibraryRemoved(const String:name[])
{
	if (StrEqual(name, "readyup")) readyUpIsAvailable = false;
}

public OnLibraryAdded(const String:name[])
{
	if (StrEqual(name, "readyup")) readyUpIsAvailable = true;
}

public Native_IsInPause(Handle:plugin, numParams)
{
	return _:isPaused;
}

public OnClientPutInServer(client)
{
	if (isPaused)
	{
		if (!IsFakeClient(client))
		{
			PrintToChatAll("\x01[SM] \x03%N \x01is now fully loaded in game", client);
			ChangeClientTeam(client, _:L4D2Team_Spectator);
		}
	}
}

public OnClientDisconnect(client)
{
	hiddenPanel[client] = false;
}

public OnMapStart()
{
	PrecacheSound("level/bell_normal.wav");
}

public RoundEnd_Event(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (deferredPauseTimer != INVALID_HANDLE)
	{
		CloseHandle(deferredPauseTimer);
		deferredPauseTimer = INVALID_HANDLE;
	}
}

public PlayerTeam_Event(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (L4D2Team:GetEventInt(event, "team") == L4D2Team_Infected)
	{
		new client = GetClientOfUserId(GetEventInt(event, "userid"));
		playerCantPause[client] = true;
		if (playerCantPauseTimers[client] != INVALID_HANDLE)
		{
			KillTimer(playerCantPauseTimers[client]);
			playerCantPauseTimers[client] = INVALID_HANDLE;
		}
		playerCantPauseTimers[client] = CreateTimer(2.0, AllowPlayerPause_Timer, client);
	}
}

public Action:Hide_Cmd(client, args)
{
	hiddenPanel[client] = true;
	return Plugin_Handled;
}

public Action:Show_Cmd(client, args)
{
	hiddenPanel[client] = false;
	return Plugin_Handled;
}

public Action:AllowPlayerPause_Timer(Handle:timer, any:client)
{
	playerCantPause[client] = false;
	playerCantPauseTimers[client] = INVALID_HANDLE;
}

public Action:Pause_Cmd(client, args)
{
	if ((!readyUpIsAvailable || !IsInReady()) && pauseDelay == 0 && !isPaused && IsPlayer(client) && !playerCantPause[client])
	{
		CPrintToChatAll("{lightgreen}%N {default}paused the game!", client);
		pauseDelay = GetConVarInt(pauseDelayCvar);
		Duration = INVALID_HANDLE;
		if (pauseDelay == 0)
			AttemptPause();
		else
			CreateTimer(1.0, PauseDelay_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}
	return Plugin_Handled;
}

public Action:PauseDelay_Timer(Handle:timer)
{
	if (pauseDelay == 0)
	{
		PrintToChatAll("Paused!");
		AttemptPause();
		return Plugin_Stop;
	}
	else
	{
		PrintToChatAll("Game pausing in: %d", pauseDelay);
		pauseDelay--;
	}
	return Plugin_Continue;
}

public Action:Unpause_Cmd(client, args)
{
	if (isPaused && IsPlayer(client) && !playerCantPause[client])
	{
		new L4D2Team:clientTeam = L4D2Team:GetClientTeam(client);
		if (!teamReady[clientTeam])
		{
			CPrintToChatAll("{lightgreen}%N {default}marked {olive}%s {default}as ready!", client, teamString[L4D2Team:GetClientTeam(client)]);
		}
		teamReady[clientTeam] = true;
		if (!adminPause && CheckFullReady())
		{
			InitiateLiveCountdown();
		}
	}
	return Plugin_Handled;
}

public Action:Unready_Cmd(client, args)
{
	if (isPaused && IsPlayer(client))
	{
		new L4D2Team:clientTeam = L4D2Team:GetClientTeam(client);
		if (teamReady[clientTeam])
		{
			CPrintToChatAll("{lightgreen}%N {default}marked {olive}%s {default}as not ready!", client, teamString[L4D2Team:GetClientTeam(client)]);
		}
		teamReady[clientTeam] = false;
		CancelFullReady(client);
	}
	return Plugin_Handled;
}

public Action:ToggleReady_Cmd(client, args)
{
	if (isPaused && IsPlayer(client))
	{
		new L4D2Team:clientTeam = L4D2Team:GetClientTeam(client);
		teamReady[clientTeam] = !teamReady[clientTeam];
		CPrintToChatAll("{lightgreen}%N {default}marked {olive}%s {default}as %sready!", client, teamString[L4D2Team:GetClientTeam(client)], teamReady[clientTeam] ? "" : "not ");
		if (!adminPause && teamReady[clientTeam] && CheckFullReady())
		{
			InitiateLiveCountdown();
		}
		else if (!teamReady[clientTeam])
		{
			CancelFullReady(client);
		}
	}
	return Plugin_Handled;
}

public Action:ForcePause_Cmd(client, args)
{
	if (!isPaused)
	{
		adminPause = true;
		Pause();
	}
}

public Action:ForceUnpause_Cmd(client, args)
{
	if (isPaused)
	{
		InitiateLiveCountdown();
	}
}

AttemptPause()
{
	if (deferredPauseTimer == INVALID_HANDLE)
	{
		if (CanPause())
		{
			Pause();
		}
		else
		{
			PrintToChatAll("[SM] This pause has been delayed due to a pick-up in progress!");
			deferredPauseTimer = CreateTimer(0.1, DeferredPause_Timer, _, TIMER_REPEAT);
		}
	}
}

public Action:DeferredPause_Timer(Handle:timer)
{
	if (CanPause())
	{
		deferredPauseTimer = INVALID_HANDLE;
		Pause();
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

Pause()
{
	for (new L4D2Team:team; team < L4D2Team; team++)
	{
		teamReady[team] = false;
	}

	isPaused = true;
	readyCountdownTimer = INVALID_HANDLE;
	if (Duration == INVALID_HANDLE)
		Duration = CreateTimer(1.0, MenuRefresh_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

	new bool:pauseProcessed = false;
	for (new client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			if(!pauseProcessed)
			{
				SetConVarBool(sv_pausable, true);
				FakeClientCommand(client, "pause");
				SetConVarBool(sv_pausable, false);
				pauseProcessed = true;
			}
			if (L4D2Team:GetClientTeam(client) == L4D2Team_Spectator)
			{
				SendConVarValue(client, sv_noclipduringpause, "1");
			}
		}
	}
	Call_StartForward(pauseForward);
	Call_Finish();
}

Unpause()
{
	isPaused = false;
	adminPause = false;

	new bool:unpauseProcessed = false;
	for (new client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			if(!unpauseProcessed)
			{
				SetConVarBool(sv_pausable, true);
				FakeClientCommand(client, "unpause");
				SetConVarBool(sv_pausable, false);
				unpauseProcessed = true;
			}
			if (L4D2Team:GetClientTeam(client) == L4D2Team_Spectator)
			{
				SendConVarValue(client, sv_noclipduringpause, "0");
			}
		}
	}
	Call_StartForward(unpauseForward);
	Call_Finish();
}

public Action:MenuRefresh_Timer(Handle:timer)
{
	if (isPaused)
	{
		UpdatePanel();
		return Plugin_Continue;
	}
	return Plugin_Handled;
}

UpdatePanel()
{
	if (menuPanel != INVALID_HANDLE)
	{
		CloseHandle(menuPanel);
		menuPanel = INVALID_HANDLE;
	}

	decl String:pause[64];
	numb++;
	menuPanel = CreatePanel();
	
	PrintAnimatedWords(); // Animated Words
	
	if (numb < 60)
		Format(pause, sizeof(pause), "Pause duration: %is", numb);
	else
	{
		new min = numb/60;
		new sec = numb-min*60;
		
		Format(pause, sizeof(pause), "Pause duration: %im %is", min, sec);
	}
	DrawPanelText(menuPanel, pause);
	
	DrawPanelText(menuPanel, " ");
	DrawPanelText(menuPanel, "Team Status");
	DrawPanelText(menuPanel, teamReady[L4D2Team_Survivor] ? "->1. Survivors: [✔]" : "->1. Survivors: [✘]");
	DrawPanelText(menuPanel, teamReady[L4D2Team_Infected] ? "->2. Infected: [✔]" : "->2. Infected: [✘]");

	for (new client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && !IsFakeClient(client) && !hiddenPanel[client])
		{
			SendPanelToClient(menuPanel, client, DummyHandler, 1);
		}
	}
}

InitiateLiveCountdown()
{
	if (readyCountdownTimer == INVALID_HANDLE)
	{
		PrintToChatAll("Going live!\nSay !unready to cancel");
		readyDelay = GetConVarInt(l4d_ready_delay);
		readyCountdownTimer = CreateTimer(1.0, ReadyCountdownDelay_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action:ReadyCountdownDelay_Timer(Handle:timer)
{
	if (readyDelay == 0)
	{
		Unpause();
		if (GetConVarBool(l4d_ready_blips))
		{
			CreateTimer(0.01, BlipDelay_Timer);
		}
		return Plugin_Stop;
	}
	else
	{
		PrintToChatAll("Live in: %d", readyDelay);
		readyDelay--;
	}
	return Plugin_Continue;
}

public Action:BlipDelay_Timer(Handle:timer)
{
	decl String:round[512];
	tg = 0; numb = 0;
	if (Duration != INVALID_HANDLE)
	{
		CloseHandle(Duration);
		Duration = INVALID_HANDLE;
	}
	EmitSoundToAll("level/bell_normal.wav", _, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 1.0);
	Format(round, sizeof(round), "%s", (InSecondHalfOfRound() ? "2" : "1"));
	PrintHintTextToAll("Round (%s/2) ... CONTINUE!", round);
}

CancelFullReady(client)
{
	if (readyCountdownTimer != INVALID_HANDLE)
	{
		CloseHandle(readyCountdownTimer);
		readyCountdownTimer = INVALID_HANDLE;
		PrintToChatAll("%N cancelled the countdown!", client);
	}
}

public Action:Say_Callback(client, const String:command[], argc)
{
	if (isPaused)
	{
		decl String:buffer[256];
		GetCmdArgString(buffer, sizeof(buffer));
		StripQuotes(buffer);
		if (IsChatTrigger() && buffer[0] == '/' || buffer[0] == '!' || buffer[0] == '@')  // Hidden command or chat trigger
		{
			return Plugin_Continue;
		}
		if (client == 0)
		{
			PrintToChatAll("Console : %s", buffer);
		}
		else
		{
			CPrintToChatAllEx(client, "{teamcolor}%N{default} :  %s", client, buffer);
		}
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public Action:TeamSay_Callback(client, const String:command[], argc)
{
	if (isPaused)
	{
		decl String:buffer[256];
		GetCmdArgString(buffer, sizeof(buffer));
		StripQuotes(buffer);
		if (IsChatTrigger() && buffer[0] == '/' || buffer[0] == '!' || buffer[0] == '@')  // Hidden command or chat trigger
		{
			return Plugin_Continue;
		}
		else
			PrintToTeam(client, L4D2Team:GetClientTeam(client), buffer);
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public Action:Unpause_Callback(client, const String:command[], argc)
{
	if (isPaused)
	{
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

bool:CheckFullReady()
{
	return (teamReady[L4D2Team_Survivor] || GetTeamHumanCount(L4D2Team_Survivor) == 0)
		&& (teamReady[L4D2Team_Infected] || GetTeamHumanCount(L4D2Team_Infected) == 0);
}

stock IsPlayer(client)
{
	new L4D2Team:team = L4D2Team:GetClientTeam(client);
	return (client && (team == L4D2Team_Survivor || team == L4D2Team_Infected));
}

stock PrintToTeam(author, L4D2Team:team, const String:buffer[])
{
	for (new client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && L4D2Team:GetClientTeam(client) == team)
		{
			CPrintToChatEx(client, author, "(%s) {teamcolor}%N{default} :  %s", teamString[L4D2Team:GetClientTeam(author)], author, buffer);
		}
	}
}

public DummyHandler(Handle:menu, MenuAction:action, param1, param2) { }

stock GetTeamHumanCount(L4D2Team:team)
{
	new humans = 0;
	
	for (new client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && L4D2Team:GetClientTeam(client) == team)
		{
			humans++;
		}
	}
	
	return humans;
}

stock bool:IsPlayerIncap(client) return bool:GetEntProp(client, Prop_Send, "m_isIncapacitated");

bool:CanPause()
{
	for (new client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && IsPlayerAlive(client) && L4D2Team:GetClientTeam(client) == L4D2Team_Survivor)
		{
			if (IsPlayerIncap(client))
			{
				if (GetEntProp(client, Prop_Send, "m_reviveOwner") > 0)
				{
					return false;
				}
			}
			else
			{
				if (GetEntProp(client, Prop_Send, "m_reviveTarget") > 0)
				{
					return false;
				}
			}
		}
	}
	return true;
}

PrintAnimatedWords()
{
	decl String:date[64];
	decl String:time[64];
	FormatTime(date, sizeof(date), "%d/%m/%Y");
	Format(date, sizeof(date), "Date: %s", date);
	FormatTime(time, sizeof(time), "%H:%M");
	Format(time, sizeof(time), "Time: %s", time);
	decl String:info[512];
	GetConVarString(FindConVar("hostname"), info, sizeof(info));
	if (tg < 13) tg++;
	if (tg == 1 || tg == 2)
		DrawPanelText(menuPanel, info);
	else if (tg == 3 || tg == 4)
		DrawPanelText(menuPanel, "☐ !hide, !show, !r, !nr");
	else if (tg == 5 || tg == 6)
		DrawPanelText(menuPanel, "★ Game is pausing ★");
	else if (tg == 7 || tg == 8)
		DrawPanelText(menuPanel, date); //Date
	else if (9 <= tg <= 12)
		DrawPanelText(menuPanel, time); //Time
	else if (tg == 13)
	{
		DrawPanelText(menuPanel, time); //Time
		tg = 0;
	}
}

InSecondHalfOfRound()
{
	return GameRules_GetProp("m_bInSecondHalfOfRound");
}