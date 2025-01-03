#pragma semicolon 1

#define PLUGIN_AUTHOR "Totenfluch"
#define PLUGIN_VERSION "3.1"

#include <sourcemod>
#include <sdktools>
#include <multicolors>
#include <autoexecconfig>

#pragma newdecls required

char dbconfig[] = "tVip";
Database g_DB;

/*
	https://wiki.alliedmods.net/Checking_Admin_Flags_(SourceMod_Scripting)
	19 -> Custom5
	20 -> Custom6
*/

Handle g_hTestVipDuration;
int g_iTestVipDuration;

Handle g_hFlag;
int g_iFlags[20];
int g_iFlagCount = 0;

Handle g_hForward_OnClientLoadedPre;
Handle g_hForward_OnClientLoadedPost;

bool g_bIsVip[MAXPLAYERS + 1];
bool g_Late;

int g_iPlayersProcessed = 0;
int g_iTotalPlayers = 0;

public Plugin myinfo = 
{
  name = "tVip", 
  author = PLUGIN_AUTHOR, 
  description = "Add time based VIPs ingame", 
  version = PLUGIN_VERSION, 
  url = "https://totenfluch.de"
};


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
  //Create natives
  CreateNative("tVip_GrantVip", NativeGrantVip);
  CreateNative("tVip_DeleteVip", NativeDeleteVip);
  g_Late = late;
  return APLRes_Success;
}

public void OnPluginStart() {
  char error[255];
  g_DB = SQL_Connect(dbconfig, true, error, sizeof(error));
  
  if (!g_DB)
  {
    SetFailState("Error connecting to database: \"%s\"", error);
  }
  
  SQL_SetCharset(g_DB, "utf8");
  
  char createTableQuery[4096] =
    "CREATE TABLE IF NOT EXISTS `tVip_vips` ( \
 		`Id` bigint(20) NOT NULL AUTO_INCREMENT, \
  		`timestamp` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP, \
  		`playername` varchar(36) COLLATE utf8_bin NOT NULL, \
  		`playerid` varchar(20) COLLATE utf8_bin NOT NULL, \
  		`enddate` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP, \
  		`admin_playername` varchar(36) COLLATE utf8_bin NOT NULL, \
  		`admin_playerid` varchar(20) COLLATE utf8_bin NOT NULL, \
 		 PRIMARY KEY (`Id`), \
  		 UNIQUE KEY `playerid` (`playerid`)  \
  		 ) ENGINE = InnoDB AUTO_INCREMENT=0 DEFAULT CHARSET=utf8 COLLATE=utf8_bin;";
  SQL_TQuery(g_DB, SQLErrorCheckCallback, createTableQuery);

  char createVipLogsTableQuery[] = 
    "CREATE TABLE IF NOT EXISTS tVip_logs ( \
        id BIGINT(20) NOT NULL AUTO_INCREMENT, \
        action_type ENUM('add', 'remove', 'extend', 'expire') NOT NULL, \
        timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, \
        target_name VARCHAR(36) COLLATE utf8_bin NOT NULL, \
        target_steamid VARCHAR(20) COLLATE utf8_bin NOT NULL, \
        admin_name VARCHAR(36) COLLATE utf8_bin NOT NULL, \
        admin_steamid VARCHAR(20) COLLATE utf8_bin NOT NULL, \
        duration INT, \
        duration_type ENUM('MONTH', 'MINUTE') NOT NULL, \
        PRIMARY KEY (id) \
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_bin;";
  SQL_TQuery(g_DB, SQLErrorCheckCallback, createVipLogsTableQuery);

  char createAdminsTableQuery[] = 
    "CREATE TABLE IF NOT EXISTS `tVip_admins` ( \
    `id` bigint(20) NOT NULL AUTO_INCREMENT, \
    `steam_id` varchar(20) COLLATE utf8_bin NOT NULL, \
    `admin_name` varchar(36) COLLATE utf8_bin NOT NULL, \
    `admin_level` int NOT NULL DEFAULT '1', \
    `timestamp` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP, \
    PRIMARY KEY (`id`), \
    UNIQUE KEY `steam_id` (`steam_id`) \
    ) ENGINE=InnoDB AUTO_INCREMENT=0 DEFAULT CHARSET=utf8 COLLATE=utf8_bin;";
  SQL_TQuery(g_DB, SQLErrorCheckCallback, createAdminsTableQuery);

  AutoExecConfig_SetFile("tVip");
  AutoExecConfig_SetCreateFile(true);
  
  g_hFlag = AutoExecConfig_CreateConVar("tVip_flag", "19", "20=Custom6, 19=Custom5 etc. Numeric Flag See: 'https://wiki.alliedmods.net/Checking_Admin_Flags_(SourceMod_Scripting)' for Definitions ---- Multiple flags seperated with Space: '16 17 18 19' !!");
  g_hTestVipDuration = AutoExecConfig_CreateConVar("tVip_testVipDuration", "15", "Test Vip duration in minutes");
  
  AutoExecConfig_CleanFile();
  AutoExecConfig_ExecuteFile();
  
  RegAdminCmd("sm_tvip", cmdtVIP, ADMFLAG_ROOT, "Opens the tVIP menu");
  RegAdminCmd("sm_addvip", cmdAddVip, ADMFLAG_ROOT, "Adds a VIP Usage: sm_addvip \"<SteamID>\" <Duration in Month> \"<Name>\" [0=Month,1=Minutes]");
  RegAdminCmd("sm_removevip", removeVip, ADMFLAG_ROOT, "Removes a VIP Usage: sm_removevip \"<SteamID>\"");
  RegConsoleCmd("sm_vips", cmdListVips, "Shows all VIPs");
  RegConsoleCmd("sm_vip", openVipPanel, "Opens the Vip Menu");
  
  g_hForward_OnClientLoadedPre = CreateGlobalForward("tVip_OnClientLoadedPre", ET_Event, Param_Cell);
  g_hForward_OnClientLoadedPost = CreateGlobalForward("tVip_OnClientLoadedPost", ET_Event, Param_Cell);
  
  if (g_Late) {
        g_iTotalPlayers = 0;
        g_iPlayersProcessed = 0;
        
        // Count valid players that need processing
        for(int i = 1; i <= MaxClients; i++) {
            if (isValidClient(i)) {
                g_iTotalPlayers++;
            }
        }
        
        // Process each player
        for(int i = 1; i <= MaxClients; i++) {
            if (isValidClient(i)) {
                OnClientPostAdminCheck(i);
            }
        }
    }
}

void ReloadAdminsAndTags()
{
  CreateTimer(5.0, Timer_ReloadAdminsAndChatTags);
}

public Action Timer_ReloadAdminsAndChatTags(Handle timer, any data) {
  ServerCommand("sm_reloadadmins");
  ServerCommand("sm_reloadccc");
  return Plugin_Continue;
}

public void OnConfigsExecuted() {
  g_iFlagCount = 0;
  g_iTestVipDuration = GetConVarInt(g_hTestVipDuration);
  char cFlags[256];
  GetConVarString(g_hFlag, cFlags, sizeof(cFlags));
  char cSplinters[20][6];
  for (int i = 0; i < 20; i++)
  strcopy(cSplinters[i], 6, "");
  ExplodeString(cFlags, " ", cSplinters, 20, 6);
  for (int i = 0; i < 20; i++) {
    if (StrEqual(cSplinters[i], ""))
      break;
    g_iFlags[g_iFlagCount++] = StringToInt(cSplinters[i]);
  }
}

public Action openVipPanel(int client, int args) {
  if (g_bIsVip[client]) {
    char playerid[20];
    if (!GetClientAuthId(client, AuthId_SteamID64, playerid, sizeof(playerid)))
    {
      CPrintToChat(client, "[SM] Error retrieving user's SteamID");
      return Plugin_Handled;
    }
    
    char getDatesQuery[1024];
    Format(getDatesQuery, sizeof(getDatesQuery), "SELECT timestamp,enddate,DATEDIFF(enddate, NOW()) as timeleft FROM tVip_vips WHERE playerid = '%s';", playerid);
    
    SQL_TQuery(g_DB, getDatesQueryCallback, getDatesQuery, client);
  }
  return Plugin_Handled;
  
}

public void getDatesQueryCallback(Handle owner, Handle hndl, const char[] error, any data) {
  int client = data;
  char ends[128];
  char started[128];
  char left[64];
  while (SQL_FetchRow(hndl)) {
    SQL_FetchString(hndl, 0, started, sizeof(started));
    SQL_FetchString(hndl, 1, ends, sizeof(ends));
    SQL_FetchString(hndl, 2, left, sizeof(left));
  }
  
  Menu VipPanelMenu = CreateMenu(VipPanelMenuHandler);
  char m_started[256];
  char m_ends[256];
  Format(m_started, sizeof(m_started), "Started: %s", started);
  Format(m_ends, sizeof(m_ends), "Ends: %s (%s Days)", ends, left);
  SetMenuTitle(VipPanelMenu, "VIP Panel");
  AddMenuItem(VipPanelMenu, "x", m_started, ITEMDRAW_DISABLED);
  AddMenuItem(VipPanelMenu, "x", m_ends, ITEMDRAW_DISABLED);
  DisplayMenu(VipPanelMenu, client, 60);
}

public int VipPanelMenuHandler(Handle menu, MenuAction action, int client, int item) {
  char cValue[32];
  GetMenuItem(menu, item, cValue, sizeof(cValue));
  if (action == MenuAction_Select) {
    // TODO ?
  }
  return 0;
}

public Action removeVip(int client, int args) {
  if (args != 1) {
    if (client != 0)
      CPrintToChat(client, "{olive}[-T-] {lightred}Invalid Params Usage: sm_removevip \"<SteamID>\"");
    else
      PrintToServer("[-T-] Invalid Params Usage: sm_removevip \"<SteamID>\"");
    return Plugin_Handled;
  }
  
  char playerid[20];
  GetCmdArg(1, playerid, sizeof(playerid));
  StripQuotes(playerid);
  deleteVip(playerid);
  
  if (client != 0)
    CPrintToChat(client, "{green}Deleted {orange}%s{green} from the Database", playerid);
  else
    PrintToServer("Deleted %s from the Database", playerid);
  
  return Plugin_Handled;
}

public Action cmdAddVip(int client, int args) {
  if (args < 3) {
    if (client != 0)
      CPrintToChat(client, "[SM] Usage: sm_addvip \"<SteamID>\" <Duration> \"<Name>\" [0=Month,1=Minutes]");
    else  
      PrintToServer("[SM] Usage: sm_addvip \"<SteamID>\" <Duration> \"<Name>\" [0=Month,1=Minutes]");
    return Plugin_Handled;
  }
  
  char steamIdInput[22];
  GetCmdArg(1, steamIdInput, sizeof(steamIdInput));
  StripQuotes(steamIdInput);
  
  char durationString[8];
  GetCmdArg(2, durationString, sizeof(durationString));
  int durationAmount = StringToInt(durationString);
  
  char cleanSteamId[20];
  strcopy(cleanSteamId, sizeof(cleanSteamId), steamIdInput);
  StripQuotes(cleanSteamId);
  
  char playerName[MAX_NAME_LENGTH + 8];
  GetCmdArg(3, playerName, sizeof(playerName));
  StripQuotes(playerName);
  char escapedPlayerName[MAX_NAME_LENGTH * 2 + 16];
  SQL_EscapeString(g_DB, playerName, escapedPlayerName, sizeof(escapedPlayerName));
  
  int durationFormat = 0; // 0=Month, 1=Minutes
  if (args == 4) {
    char durationFormatString[8];
    GetCmdArg(4, durationFormatString, sizeof(durationFormatString));
    durationFormat = StringToInt(durationFormatString);
  }
  
  grantVipEx(client, cleanSteamId, durationAmount, escapedPlayerName, durationFormat);
  return Plugin_Handled;
}

public Action cmdtVIP(int client, int args) {
  Menu mainChooser = CreateMenu(mainChooserHandler);
  SetMenuTitle(mainChooser, "Totenfluchs tVIP Control");
  AddMenuItem(mainChooser, "add", "Add VIP");
  AddMenuItem(mainChooser, "remove", "Remove VIP");
  AddMenuItem(mainChooser, "extend", "Extend VIP");
  AddMenuItem(mainChooser, "list", "List VIPs (Info)");
  DisplayMenu(mainChooser, client, 60);
  return Plugin_Handled;
}

public Action cmdListVips(int client, int args) {
  char showOffVIPQuery[1024];
  Format(showOffVIPQuery, sizeof(showOffVIPQuery), "SELECT playername,playerid FROM tVip_vips WHERE NOW() < enddate;");
  SQL_TQuery(g_DB, SQLShowOffVipQuery, showOffVIPQuery, client);
  return Plugin_Handled;
}

public void SQLShowOffVipQuery(Handle owner, Handle hndl, const char[] error, any data) {
  int client = data;
  Menu showOffMenu = CreateMenu(noMenuHandler);
  SetMenuTitle(showOffMenu, ">>> VIPs <<<");
  while (SQL_FetchRow(hndl)) {
    char playerid[20];
    char playername[MAX_NAME_LENGTH + 8];
    SQL_FetchString(hndl, 0, playername, sizeof(playername));
    SQL_FetchString(hndl, 1, playerid, sizeof(playerid));
    AddMenuItem(showOffMenu, playerid, playername, ITEMDRAW_DISABLED);
  }
  DisplayMenu(showOffMenu, client, 60);
}

public int noMenuHandler(Handle menu, MenuAction action, int client, int item) { return 0; }

public int mainChooserHandler(Handle menu, MenuAction action, int client, int item) {
  char cValue[32];
  GetMenuItem(menu, item, cValue, sizeof(cValue));
  if (action == MenuAction_Select) {
    if (StrEqual(cValue, "add")) {
      showDurationSelect(client, 1);
    } else if (StrEqual(cValue, "remove")) {
      showAllVIPsToAdmin(client);
    } else if (StrEqual(cValue, "extend")) {
      extendSelect(client);
    } else if (StrEqual(cValue, "list")) {
      listUsers(client);
    }
  }
  return 0;
}

int g_iReason[MAXPLAYERS + 1];
public void showDurationSelect(int client, int reason) {
  Menu selectDuration = CreateMenu(selectDurationHandler);
  SetMenuTitle(selectDuration, "Select the Duration");
  AddMenuItem(selectDuration, "testVip", "Test Vip");
  AddMenuItem(selectDuration, "1", "1 Month");
  AddMenuItem(selectDuration, "2", "2 Month");
  AddMenuItem(selectDuration, "3", "3 Month");
  AddMenuItem(selectDuration, "4", "4 Month");
  AddMenuItem(selectDuration, "5", "5 Month");
  AddMenuItem(selectDuration, "6", "6 Month");
  AddMenuItem(selectDuration, "9", "9 Month");
  AddMenuItem(selectDuration, "12", "12 Month");
  g_iReason[client] = reason;
  DisplayMenu(selectDuration, client, 60);
}

int g_iDurationSelected[MAXPLAYERS + 1];
public int selectDurationHandler(Handle menu, MenuAction action, int client, int item) {
  char cValue[32];
  GetMenuItem(menu, item, cValue, sizeof(cValue));
  if (action == MenuAction_Select) {
    if (StrEqual(cValue, "testVip")) {
      g_iDurationSelected[client] = g_iTestVipDuration;
      g_iReason[client] = 3;
      showPlayerSelectMenu(client, g_iReason[client]);
    } else {
      g_iDurationSelected[client] = StringToInt(cValue);
      showPlayerSelectMenu(client, g_iReason[client]);
    }
  }
  return 0;
}

public void showPlayerSelectMenu(int client, int reason) {
  Handle menu;
  char menuTitle[255];
  if (reason == 1) {
    menu = CreateMenu(targetChooserMenuHandler);
    Format(menuTitle, sizeof(menuTitle), "Select a Player to grant %i Month", g_iDurationSelected[client]);
  } else if (reason == 2) {
    menu = CreateMenu(extendChooserMenuHandler);
    Format(menuTitle, sizeof(menuTitle), "Select a Player to extend %i Month", g_iDurationSelected[client]);
  } else if (reason == 3) {
    menu = CreateMenu(targetChooserMenuHandler);
    Format(menuTitle, sizeof(menuTitle), "Select a Player to grant Test Vip (%i Minutes)", g_iDurationSelected[client]);
  }
  if (menu == INVALID_HANDLE)
    return;
  SetMenuTitle(menu, menuTitle);
  int pAmount = 0;
  for (int i = 1; i <= MAXPLAYERS; i++) {
    if (i == client)
      continue;
    
    if (!isValidClient(i))
      continue;
    
    if (IsFakeClient(i))
      continue;
    
    if (reason == 2) {
      if (!g_bIsVip[i])
        continue;
    } else if (reason == 1) {
      if (g_bIsVip[i])
        continue;
    }
    
    char Id[64];
    IntToString(i, Id, sizeof(Id));
    
    char targetName[MAX_NAME_LENGTH + 1];
    GetClientName(i, targetName, sizeof(targetName));
    
    AddMenuItem(menu, Id, targetName);
    pAmount++;
  }
  if (pAmount == 0)
    CPrintToChat(client, "{red}No matching clients found (Noone there or everyone is already VIP/Admin)");
  
  DisplayMenu(menu, client, 30);
}

public int targetChooserMenuHandler(Handle menu, MenuAction action, int client, int item) {
  if (action == MenuAction_Select) {
    char info[64];
    GetMenuItem(menu, item, info, sizeof(info));
    
    int target = StringToInt(info);
    if (!isValidClient(target) || !IsClientInGame(target)) {
      CPrintToChat(client, "{red}Invalid Target");
      return 0;
    }
    
    grantVip(client, target, g_iDurationSelected[client], g_iReason[client]);
  }
  if (action == MenuAction_End) {
    delete menu;
  }
  return 0;
}

public void grantVip(int admin, int client, int duration, int reason) {
  char admin_playerid[20];
  char admin_playername[MAX_NAME_LENGTH + 8];
  if (admin != 0)
  {
    if (!GetClientAuthId(admin, AuthId_SteamID64, admin_playerid, sizeof(admin_playerid)))
    {
      CPrintToChat(admin, "[SM] Error retrieving admin's SteamID");
      return;
    }
    GetClientName(admin, admin_playername, sizeof(admin_playername));
  }
  else
  {
    strcopy(admin_playerid, sizeof(admin_playername), "SERVER-CONSOLE");
    strcopy(admin_playerid, sizeof(admin_playerid), "SERVER-CONSOLE");
  }
  char clean_admin_playername[MAX_NAME_LENGTH * 2 + 16];
  SQL_EscapeString(g_DB, admin_playername, clean_admin_playername, sizeof(clean_admin_playername));
  
  char playerid[20];
  if (!GetClientAuthId(client, AuthId_SteamID64, playerid, sizeof(playerid)))
  {
    CPrintToChat(client, "[SM] Error retrieving user's SteamID");
    return;
  }
  char playername[MAX_NAME_LENGTH + 8];
  GetClientName(client, playername, sizeof(playername));
  char clean_playername[MAX_NAME_LENGTH * 2 + 16];
  SQL_EscapeString(g_DB, playername, clean_playername, sizeof(clean_playername));
  
  
  char addVipQuery[4096];
  Format(addVipQuery, sizeof(addVipQuery), "INSERT IGNORE INTO `tVip_vips` (`Id`, `timestamp`, `playername`, `playerid`, `enddate`, `admin_playername`, `admin_playerid`) VALUES (NULL, CURRENT_TIMESTAMP, '%s', '%s', CURRENT_TIMESTAMP, '%s', '%s');", clean_playername, playerid, clean_admin_playername, admin_playerid);
  SQL_TQuery(g_DB, SQLErrorCheckCallback, addVipQuery);
  
  char updateTime[1024];
  if (reason != 3)
    Format(updateTime, sizeof(updateTime), "UPDATE tVip_vips SET enddate = DATE_ADD(enddate, INTERVAL %i MONTH) WHERE playerid = '%s';", duration, playerid);
  else
    Format(updateTime, sizeof(updateTime), "UPDATE tVip_vips SET enddate = DATE_ADD(enddate, INTERVAL %i MINUTE) WHERE playerid = '%s';", duration, playerid);
  SQL_TQuery(g_DB, SQLErrorCheckCallback, updateTime);
  
  CPrintToChat(admin, "{green}Added {orange}%s{green} as VIP for {orange}%i{green} %s", playername, duration, reason == 3 ? "Minutes":"Month");
  CPrintToChat(client, "{green}You've been granted {orange}%i{green} %s of {orange}VIP{green} by {orange}%N", duration, reason == 3 ? "Minutes":"Month", admin);
  setFlags(client);

  LogVipAction("add", 
                 playername, 
                 playerid, 
                 admin_playername, 
                 admin_playerid, 
                 duration, 
                 reason == 3 ? "MINUTE" : "MONTH");
}

public void grantVipEx(int adminId, char targetSteamId[20], int vipDuration, char[] targetName, int durationFormat) {
  char adminSteamId[20];
  if (adminId != 0) {
    if (!GetClientAuthId(adminId, AuthId_SteamID64, adminSteamId, sizeof(adminSteamId)))
    {
      CPrintToChat(adminId, "[SM] Error retrieving admin's SteamID");
      return;
    }
  } else
    strcopy(adminSteamId, sizeof(adminSteamId), "SERVER-CONSOLE");

  char adminName[MAX_NAME_LENGTH + 8];
  if (adminId != 0)
    GetClientName(adminId, adminName, sizeof(adminName));
  else
    strcopy(adminName, sizeof(adminName), "SERVER-CONSOLE");

  char escapedAdminName[MAX_NAME_LENGTH * 2 + 16];
  SQL_EscapeString(g_DB, adminName, escapedAdminName, sizeof(escapedAdminName));
  
  char insertVipQuery[4096];
  Format(insertVipQuery, sizeof(insertVipQuery), 
         "INSERT IGNORE INTO `tVip_vips` (`Id`, `timestamp`, `playername`, `playerid`, `enddate`, `admin_playername`, `admin_playerid`) " ...
         "VALUES (NULL, CURRENT_TIMESTAMP, '%s', '%s', CURRENT_TIMESTAMP, '%s', '%s');",
         targetName, targetSteamId, escapedAdminName, adminSteamId);
  SQL_TQuery(g_DB, SQLErrorCheckCallback, insertVipQuery);
  
  char updateDurationQuery[1024];
  if (durationFormat == 1) {
    Format(updateDurationQuery, sizeof(updateDurationQuery), 
           "UPDATE tVip_vips SET enddate = DATE_ADD(enddate, INTERVAL %i MINUTE) WHERE playerid = '%s';", 
           vipDuration, targetSteamId);
  } else {
    Format(updateDurationQuery, sizeof(updateDurationQuery), 
           "UPDATE tVip_vips SET enddate = DATE_ADD(enddate, INTERVAL %i MONTH) WHERE playerid = '%s';", 
           vipDuration, targetSteamId);
  }
  SQL_TQuery(g_DB, SQLErrorCheckCallback, updateDurationQuery);
  
  if (adminId != 0)
    CPrintToChat(adminId, "{green}Added {orange}%s{green} as VIP for {orange}%i{green} Month", targetSteamId, vipDuration);
  else
    PrintToServer("Added %s as VIP for %i Month", targetSteamId, vipDuration);

  LogVipAction("add", 
               targetName,     
               targetSteamId,   
               adminName,      
               adminSteamId,   
               vipDuration,    
               durationFormat == 1 ? "MINUTE" : "MONTH"); 
}

public void OnClientPostAdminCheck(int client) {
    // Before cleanup, get expired VIPs for logging
    char getExpiredQuery[256];
    Format(getExpiredQuery, sizeof(getExpiredQuery), 
        "SELECT playername, playerid FROM tVip_vips WHERE enddate < NOW();");
    SQL_TQuery(g_DB, SQL_LogExpiredVipsCallback, getExpiredQuery);
    
    g_bIsVip[client] = false;
    char cleanUp[256];
    Format(cleanUp, sizeof(cleanUp), "DELETE FROM tVip_vips WHERE enddate < NOW();");
    SQL_TQuery(g_DB, SQLErrorCheckCallback, cleanUp);
    
    loadVip(client);
    
    // If it's a late load, track progress
    if (g_Late) {
        g_iPlayersProcessed++;
        
        // If all players have been processed, reload admins and tags
        if (g_iPlayersProcessed >= g_iTotalPlayers) {
            g_Late = false; // Reset late load flag
            ReloadAdminsAndTags();
        }
    } else {
        // Not a late load, just a normal player join - reload immediately
        ReloadAdminsAndTags();
    }
}

public void SQL_LogExpiredVipsCallback(Handle owner, Handle hndl, const char[] error, any data) {
    while (SQL_FetchRow(hndl)) {
        char playername[MAX_NAME_LENGTH + 8];
        char playerid[20];
        SQL_FetchString(hndl, 0, playername, sizeof(playername));
        SQL_FetchString(hndl, 1, playerid, sizeof(playerid));
        
        LogVipAction("expire", playername, playerid, "SYSTEM", "SYSTEM");
    }
}

public void loadVip(int client) {
  char playerid[20];
  if (!GetClientAuthId(client, AuthId_SteamID64, playerid, sizeof(playerid)))
  {
    CPrintToChat(client, "[SM] Error retrieving user's SteamID");
    return;
  }
  char isVipQuery[1024];
  Format(isVipQuery, sizeof(isVipQuery), "SELECT * FROM tVip_vips WHERE playerid = '%s' AND enddate > NOW();", playerid);
  
  //Pass the userid to prevent assigning flags to a wrong client
  SQL_TQuery(g_DB, SQLCheckVIPQuery, isVipQuery, GetClientUserId(client));
}

public void SQLCheckVIPQuery(Handle owner, Handle hndl, const char[] error, any data) {
  int client = GetClientOfUserId(data);
  
  Action result = Plugin_Continue;
  Call_StartForward(g_hForward_OnClientLoadedPre);
  Call_PushCell(client);
  Call_Finish(result);
  
  if (result != Plugin_Continue && result != Plugin_Changed)
  {
    return;
  }
  
  //Check if the user is still ingame
  if (isValidClient(client)) {
    while (SQL_FetchRow(hndl)) {
      setFlags(client);
    }
  }
  
  Call_StartForward(g_hForward_OnClientLoadedPost);
  Call_PushCell(client);
  Call_Finish();
  
}

public void setFlags(int client) {
  g_bIsVip[client] = true;
  for (int i = 0; i < g_iFlagCount; i++)
  SetUserFlagBits(client, GetUserFlagBits(client) | (1 << g_iFlags[i]));
}

public void removeFlags(const char[] playerid) {
  for (int i = 1; i <= MAXPLAYERS; i++) {
    if (!isValidClient(i))
      continue;
    char authId[20];
    if (!GetClientAuthId(i, AuthId_SteamID64, authId, sizeof(authId)))
      continue;
    if (StrEqual(authId, playerid))
      for (int j = 0; j < g_iFlagCount; j++)
        SetUserFlagBits(i, GetUserFlagBits(i) & ~(1 << g_iFlags[j]));
  }
}

public void OnRebuildAdminCache(AdminCachePart part) {
  if (part == AdminCache_Admins)
    reloadVIPs();
}

public void reloadVIPs() {
  for (int i = 1; i < MAXPLAYERS; i++) {
    if (!isValidClient(i))
      continue;
    loadVip(i);
  }
}

public void showAllVIPsToAdmin(int client) {
  char selectAllVIPs[1024];
  Format(selectAllVIPs, sizeof(selectAllVIPs), "SELECT playername,playerid FROM tVip_vips WHERE NOW() < enddate;");
  SQL_TQuery(g_DB, SQLListVIPsForRemoval, selectAllVIPs, client);
}

public void SQLListVIPsForRemoval(Handle owner, Handle hndl, const char[] error, any data) {
  int client = data;
  Menu menuToRemoveClients = CreateMenu(menuToRemoveClientsHandler);
  SetMenuTitle(menuToRemoveClients, "Delete a VIP");
  while (SQL_FetchRow(hndl)) {
    char playerid[20];
    char playername[MAX_NAME_LENGTH + 8];
    SQL_FetchString(hndl, 0, playername, sizeof(playername));
    SQL_FetchString(hndl, 1, playerid, sizeof(playerid));
    AddMenuItem(menuToRemoveClients, playerid, playername);
  }
  DisplayMenu(menuToRemoveClients, client, 60);
}

public int menuToRemoveClientsHandler(Handle menu, MenuAction action, int client, int item) {
  if (action == MenuAction_Select) {
    char info[20];
    char display[MAX_NAME_LENGTH + 8];
    int flags;
    GetMenuItem(menu, item, info, sizeof(info), flags, display, sizeof(display));
    deleteVip(info);
    showAllVIPsToAdmin(client);
    CPrintToChat(client, "{green}Removed {orange}%ss{green} VIP Status {green}({orange}%s{green})", display, info);
  }
  return 0;
}

public void deleteVip(char[] playerid) {
    // Get player info before deletion for logging
    char query[512];
    Format(query, sizeof(query), "SELECT playername FROM tVip_vips WHERE playerid = '%s';", playerid);
    DataPack pack = new DataPack();
    pack.WriteString(playerid);
    SQL_TQuery(g_DB, SQL_DeleteVipCallback, query, pack);
}

public void SQL_DeleteVipCallback(Handle owner, Handle hndl, const char[] error, DataPack pack) {
    pack.Reset();
    char playerid[20];
    pack.ReadString(playerid, sizeof(playerid));
    delete pack;
    
    if (SQL_FetchRow(hndl)) {
        char playername[MAX_NAME_LENGTH + 8];
        SQL_FetchString(hndl, 0, playername, sizeof(playername));
        
        // Log the removal
        LogVipAction("remove", 
                    playername, 
                    playerid, 
                    "CONSOLE", 
                    "CONSOLE");
                    
        // Now delete the VIP
        char deleteVipQuery[512];
        Format(deleteVipQuery, sizeof(deleteVipQuery), "DELETE FROM tVip_vips WHERE playerid = '%s';", playerid);
        SQL_TQuery(g_DB, SQLErrorCheckCallback, deleteVipQuery);
        removeFlags(playerid);
    }

    // Get client from steam id (playerid is 76561198xxxxxx), and remove client vip flags
    int client = GetClientOfUserId(StringToInt(playerid));
    if (isValidClient(client)) {
        g_bIsVip[client] = false;
        for (int i = 0; i < g_iFlagCount; i++)
            SetUserFlagBits(client, GetUserFlagBits(client) & ~(1 << g_iFlags[i]));
    }
}

public void extendSelect(int client) {
  showDurationSelect(client, 2);
}

public int extendChooserMenuHandler(Handle menu, MenuAction action, int client, int item) {
  if (action == MenuAction_Select) {
    char info[64];
    GetMenuItem(menu, item, info, sizeof(info));
    
    int target = StringToInt(info);
    if (!isValidClient(target) || !IsClientInGame(target)) {
      CPrintToChat(client, "{red}Invalid Target");
      return 0;
    }
    
    int userTarget = GetClientUserId(target);
    extendVip(client, userTarget, g_iDurationSelected[client]);
  }
  if (action == MenuAction_End) {
    delete menu;
  }
  return 0;
}

public void extendVip(int client, int userTarget, int duration) {
  int theUserTarget = GetClientOfUserId(userTarget);
  char playerid[20];
  if (!GetClientAuthId(theUserTarget, AuthId_SteamID64, playerid, sizeof(playerid)))
  {
    CPrintToChat(client, "[SM] Error retrieving user's SteamID");
    return;
  }
  char playername[MAX_NAME_LENGTH + 8];
  GetClientName(theUserTarget, playername, sizeof(playername));
  char clean_playername[MAX_NAME_LENGTH * 2 + 16];
  SQL_EscapeString(g_DB, playername, clean_playername, sizeof(clean_playername));
  
  char updateQuery[1024];
  Format(updateQuery, sizeof(updateQuery), "UPDATE tVip_vips SET enddate = DATE_ADD(enddate, INTERVAL %i MONTH) WHERE playerid = '%s';", duration, playerid);
  SQL_TQuery(g_DB, SQLErrorCheckCallback, updateQuery);
  
  Format(updateQuery, sizeof(updateQuery), "UPDATE tVip_vips SET playername = '%s' WHERE playerid = '%s';", clean_playername, playerid);
  SQL_TQuery(g_DB, SQLErrorCheckCallback, updateQuery);
  
  CPrintToChat(client, "{green}Extended {orange}%s{green} VIP Status by {orange}%i{green} Month", playername, duration);

  char admin_playerid[20];
  char admin_playername[MAX_NAME_LENGTH + 8];
  if (!GetClientAuthId(client, AuthId_SteamID64, admin_playerid, sizeof(admin_playerid)))
  {
    CPrintToChat(client, "[SM] Error retrieving admin's SteamID");
    Format(admin_playerid, sizeof(admin_playerid), "Unknown");
  }
  GetClientName(client, admin_playername, sizeof(admin_playername));
  LogVipAction("extend", 
                 playername, 
                 playerid, 
                 client == 0 ? "CONSOLE" : admin_playername, 
                 client == 0 ? "CONSOLE" : admin_playerid, 
                 duration, 
                 "MONTH");
}

public void listUsers(int client) {
  char listVipsQuery[1024];
  Format(listVipsQuery, sizeof(listVipsQuery), "SELECT playername,playerid FROM tVip_vips WHERE enddate > NOW();");
  SQL_TQuery(g_DB, SQLListVIPsQuery, listVipsQuery, client);
}

public void SQLListVIPsQuery(Handle owner, Handle hndl, const char[] error, any data) {
  int client = data;
  Menu menuToRemoveClients = CreateMenu(listVipsMenuHandler);
  SetMenuTitle(menuToRemoveClients, "All VIPs");
  while (SQL_FetchRow(hndl)) {
    char playerid[20];
    char playername[MAX_NAME_LENGTH + 8];
    SQL_FetchString(hndl, 0, playername, sizeof(playername));
    SQL_FetchString(hndl, 1, playerid, sizeof(playerid));
    AddMenuItem(menuToRemoveClients, playerid, playername);
  }
  DisplayMenu(menuToRemoveClients, client, 60);
}

public int listVipsMenuHandler(Handle menu, MenuAction action, int client, int item) {
  if (action == MenuAction_Select) {
    char cValue[20];
    GetMenuItem(menu, item, cValue, sizeof(cValue));
    char detailsQuery[512];
    Format(detailsQuery, sizeof(detailsQuery), "SELECT playername,playerid,enddate,timestamp,admin_playername,admin_playerid FROM tVip_vips WHERE playerid = '%s';", cValue);
    SQL_TQuery(g_DB, SQLDetailsQuery, detailsQuery, client);
  }
  return 0;
}

public void SQLDetailsQuery(Handle owner, Handle hndl, const char[] error, any data) {
  int client = data;
  Menu detailsMenu = CreateMenu(detailsMenuHandler);
  bool hasData = false;
  while (SQL_FetchRow(hndl) && !hasData) {
    char playerid[20];
    char playername[MAX_NAME_LENGTH + 8];
    char startDate[128];
    char endDate[128];
    char adminname[MAX_NAME_LENGTH + 8];
    char adminplayerid[20];
    SQL_FetchString(hndl, 0, playername, sizeof(playername));
    SQL_FetchString(hndl, 1, playerid, sizeof(playerid));
    SQL_FetchString(hndl, 2, endDate, sizeof(endDate));
    SQL_FetchString(hndl, 3, startDate, sizeof(startDate));
    SQL_FetchString(hndl, 4, adminname, sizeof(adminname));
    SQL_FetchString(hndl, 5, adminplayerid, sizeof(adminplayerid));
    
    char title[64];
    Format(title, sizeof(title), "Details: %s", playername);
    SetMenuTitle(detailsMenu, title);
    
    char playeridItem[64];
    Format(playeridItem, sizeof(playeridItem), "STEAMID: %s", playerid);
    AddMenuItem(detailsMenu, "x", playeridItem, ITEMDRAW_DISABLED);
    
    char endItem[64];
    Format(endItem, sizeof(endItem), "Ends: %s", endDate);
    AddMenuItem(detailsMenu, "x", endItem, ITEMDRAW_DISABLED);
    
    char startItem[64];
    Format(startItem, sizeof(startItem), "Started: %s", startDate);
    AddMenuItem(detailsMenu, "x", startItem, ITEMDRAW_DISABLED);
    
    char adminNItem[64];
    Format(adminNItem, sizeof(adminNItem), "By Admin: %s", adminname);
    AddMenuItem(detailsMenu, "x", adminNItem, ITEMDRAW_DISABLED);
    
    char adminIItem[64];
    Format(adminIItem, sizeof(adminIItem), "Admin ID: %s", adminplayerid);
    AddMenuItem(detailsMenu, "x", adminIItem, ITEMDRAW_DISABLED);
    
    hasData = true;
  }
  DisplayMenu(detailsMenu, client, 60);
}

public int detailsMenuHandler(Handle menu, MenuAction action, int client, int item) {
  if (action == MenuAction_Select) {
    
  } else if (action == MenuAction_Cancel) {
    listUsers(client);
  }
  return 0;
}

stock bool isValidClient(int client) {
  return (1 <= client <= MaxClients && IsClientInGame(client));
}

public void SQLErrorCheckCallback(Handle owner, Handle hndl, const char[] error, any data) {
  if (!StrEqual(error, ""))
  {
    LogError(error);
  }
}

void LogVipAction(const char[] action_type, const char[] target_name, const char[] target_steamid, 
                  const char[] admin_name, const char[] admin_steamid, int duration = 0, const char[] duration_type = "") {
    char clean_target_name[MAX_NAME_LENGTH * 2 + 16];
    char clean_admin_name[MAX_NAME_LENGTH * 2 + 16];
    
    SQL_EscapeString(g_DB, target_name, clean_target_name, sizeof(clean_target_name));
    SQL_EscapeString(g_DB, admin_name, clean_admin_name, sizeof(clean_admin_name));
    
    char query[1024];
    if (duration > 0) {
        Format(query, sizeof(query), 
            "INSERT INTO tVip_logs (action_type, target_name, target_steamid, admin_name, admin_steamid, duration, duration_type) \
             VALUES ('%s', '%s', '%s', '%s', '%s', %d, '%s')",
            action_type, clean_target_name, target_steamid, clean_admin_name, admin_steamid, duration, duration_type);
    } else {
        Format(query, sizeof(query), 
            "INSERT INTO tVip_logs (action_type, target_name, target_steamid, admin_name, admin_steamid) \
             VALUES ('%s', '%s', '%s', '%s', '%s')",
            action_type, clean_target_name, target_steamid, clean_admin_name, admin_steamid);
    }
    
    SQL_TQuery(g_DB, SQLErrorCheckCallback, query);
}

//Natives

public int NativeGrantVip(Handle myplugin, int argc)
{
  int client = GetNativeCell(1);
  int admin = GetNativeCell(2);
  int duration = GetNativeCell(3);
  int format = GetNativeCell(4);
  if (format == 1)
    format = 3;
  else if (format == 0)
    format = 1;
  else
  {
    ThrowNativeError(SP_ERROR_NATIVE, "Invalid time format (%d)", format);
    return 0;
  }
  if (admin < 1 || admin > MaxClients)
  {
    ThrowNativeError(SP_ERROR_NATIVE, "Invalid admin index (%d)", admin);
    return 0;
  }
  if (!IsClientConnected(admin))
  {
    ThrowNativeError(SP_ERROR_NATIVE, "Admin %d is not connected", admin);
    return 0;
  }
  if (client < 1 || client > MaxClients)
  {
    
    ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
    return 0;
  }
  if (!IsClientConnected(client))
  {
    ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
    return 0;
  }
  grantVip(admin, client, duration, format);
  return 0;
}


public int NativeDeleteVip(Handle myplugin, int argc)
{
  char playerid[20];
  GetNativeString(1, playerid, sizeof(playerid));
  StripQuotes(playerid);
  deleteVip(playerid);
  return 0;
} 