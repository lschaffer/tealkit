// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class LDe extends L {
  LDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'TealKit';

  @override
  String get appSubtitle => 'Dein persönlicher KI-Assistent';

  @override
  String get getStarted => 'Loslegen';

  @override
  String get viewLogs => 'Protokolle';

  @override
  String get playground => 'Playground';

  @override
  String get playgroundHint =>
      'Probiere Prompts, Tools und Systemanweisungen hier aus, bevor du einen Workflow planst.';

  @override
  String get tasks => 'Workflows';

  @override
  String get firstStep => 'Erster Schritt';

  @override
  String get settings => 'Einstellungen';

  @override
  String get configureLlmFirst =>
      'Konfiguriere einen LLM-Anbieter, um Playground und Workflows freizuschalten.';

  @override
  String get systemPrompt => 'System-Prompt';

  @override
  String get initialPrompt => 'Anfangseingabe';

  @override
  String get generatePrompt => 'Generieren';

  @override
  String get generateSystemPromptHint =>
      'Thema eingeben und ✦ tippen, um einen KI-generierten System Prompt zu erstellen.';

  @override
  String get promptSubject => 'Thema (z.B. Dokumentensuche)';

  @override
  String get selectTools => 'Tools auswählen';

  @override
  String toolsSelected(int count) {
    return '$count Tools ausgewählt';
  }

  @override
  String get resetChat => 'Chat zurücksetzen';

  @override
  String get gmailSearch => 'Gmail (Suche)';

  @override
  String get imapSend => 'SMTP (Senden)';

  @override
  String get testVia => 'Testen über';

  @override
  String get emailSearchGmail => 'Gmail API für E-Mail-Suche verwenden';

  @override
  String get emailSendImap => 'SMTP zum Senden von E-Mails verwenden';

  @override
  String get taskScheduler => 'Workflow-Zeitplaner';

  @override
  String get newTask => 'Neuer Workflow';

  @override
  String get editTask => 'Workflow bearbeiten';

  @override
  String get createTask => 'Workflow erstellen';

  @override
  String get saveAsTask => 'Als Workflow speichern';

  @override
  String get deleteTask => 'Workflow löschen';

  @override
  String deleteTaskConfirm(String name) {
    return 'Bist du sicher, dass du \"$name\" löschen möchtest?';
  }

  @override
  String get taskCreated => 'Workflow erstellt';

  @override
  String get taskUpdated => 'Workflow aktualisiert';

  @override
  String taskDeleted(String name) {
    return 'Workflow \"$name\" gelöscht';
  }

  @override
  String failedToSave(String error) {
    return 'Speichern fehlgeschlagen: $error';
  }

  @override
  String failedToLoad(String error) {
    return 'Laden der Workflows fehlgeschlagen: $error';
  }

  @override
  String get save => 'Speichern';

  @override
  String get cancel => 'Abbrechen';

  @override
  String get ok => 'OK';

  @override
  String get filterScheduledOnly => 'Nur geplant';

  @override
  String get filterAllTasks => 'Alle Workflows';

  @override
  String get close => 'Schließen';

  @override
  String get delete => 'Löschen';

  @override
  String get edit => 'Bearbeiten';

  @override
  String get copy => 'Kopieren';

  @override
  String get remove => 'Entfernen';

  @override
  String get reload => 'Aktualisieren';

  @override
  String get enable => 'Aktivieren';

  @override
  String get disable => 'Deaktivieren';

  @override
  String get enabled => 'Aktiviert';

  @override
  String get disabled => 'Deaktiviert';

  @override
  String get yes => 'Ja';

  @override
  String get no => 'Nein';

  @override
  String get tabBasic => 'Basis';

  @override
  String get tabPrompts => 'Prompts';

  @override
  String get tabSchedule => 'Zeitplan';

  @override
  String get tabLlm => 'LLM';

  @override
  String get tabMcp => 'MCP';

  @override
  String get tabBuiltIn => 'Tools';

  @override
  String get tabData => 'Datenquellen';

  @override
  String get tabNotify => 'Ausgabe';

  @override
  String get sectionGeneral => 'Allgemein';

  @override
  String get sectionPrompts => 'Prompts';

  @override
  String get sectionSchedule => 'Zeitplan';

  @override
  String get sectionExecution => 'Ausführung';

  @override
  String get taskName => 'Workflow-Name *';

  @override
  String get taskNameHint => 'z. B. Tägliche Nachrichtenzusammenfassung';

  @override
  String get nameRequired => 'Name ist erforderlich';

  @override
  String get description => 'Beschreibung';

  @override
  String get descriptionHint => 'Was macht diese Aufgabe?';

  @override
  String get agentId => 'Agent-ID';

  @override
  String get agentIdHint => 'Optional: mit einem bestimmten Agenten verknüpfen';

  @override
  String get tags => 'Tags';

  @override
  String get tagsHint => 'kommagetrennt: nachrichten, täglich, zusammenfassung';

  @override
  String get taskEnabledSubtitle =>
      'Workflow wird nach Zeitplan ausgeführt, wenn er aktiviert ist';

  @override
  String get systemPromptHint => 'Du bist ein hilfreicher Assistent...';

  @override
  String get taskPrompt => 'Workflow-Prompt *';

  @override
  String get taskPromptHint =>
      'Fasse die wichtigsten KI-Nachrichten der letzten 24 Stunden zusammen...';

  @override
  String get promptRequired => 'Prompt ist erforderlich';

  @override
  String get cronSchedule => 'Cron-Zeitplan';

  @override
  String get cronExpression => 'Cron-Ausdruck *';

  @override
  String get cronFormat => 'Format: Minute Stunde Tag Monat Wochentag';

  @override
  String get cronRequired => 'Cron-Ausdruck erforderlich';

  @override
  String get scheduleDescription => 'Zeitplanbeschreibung';

  @override
  String get scheduleDescriptionHint => 'z. B. Täglich um 8:00';

  @override
  String get cronEveryMinute => 'Jede Minute';

  @override
  String get cronHourly => 'Stündlich';

  @override
  String get cronDaily8am => 'Täglich 8 Uhr';

  @override
  String get cronDaily6pm => 'Täglich 18 Uhr';

  @override
  String get cronMonFri9am => 'Mo–Fr 9 Uhr';

  @override
  String get cronWeeklyMon => 'Wöchentlich (Mo)';

  @override
  String get cronMonthly1st => 'Monatlich 1.';

  @override
  String get schedulePickerTitle => 'Zeitplan';

  @override
  String get scheduleMinutes => 'Minuten';

  @override
  String get scheduleHourly => 'Stündlich';

  @override
  String get scheduleDaily => 'Täglich';

  @override
  String get scheduleWeekly => 'Wöchentlich';

  @override
  String get scheduleMonthly => 'Monatlich';

  @override
  String get scheduleCustom => 'Benutzerdefiniert';

  @override
  String scheduleEveryNMinutes(int n) {
    return 'Alle $n Minuten';
  }

  @override
  String scheduleEveryNHours(int n) {
    return 'Alle $n Stunden';
  }

  @override
  String get scheduleAtHour => 'Um Stunde';

  @override
  String get scheduleAtMinute => 'Um Minute';

  @override
  String get scheduleOnDays => 'An Tagen';

  @override
  String get scheduleOnDayOfMonth => 'Am Tag des Monats';

  @override
  String get scheduleMon => 'Mo';

  @override
  String get scheduleTue => 'Di';

  @override
  String get scheduleWed => 'Mi';

  @override
  String get scheduleThu => 'Do';

  @override
  String get scheduleFri => 'Fr';

  @override
  String get scheduleSat => 'Sa';

  @override
  String get scheduleSun => 'So';

  @override
  String get errorHandling => 'Fehlerbehandlung';

  @override
  String get maxRetries => 'Max. Wiederholungen';

  @override
  String get retryDelay => 'Wiederholungsverzögerung (Min.)';

  @override
  String get timeout => 'Zeitüberschreitung (Sek.)';

  @override
  String get retryOnFailure => 'Bei Fehler wiederholen';

  @override
  String get executeImmediately => 'Sofort ausführen';

  @override
  String get llmOverride => 'LLM-Konfiguration';

  @override
  String get overrideDefaultLlm => 'Standard-LLM überschreiben';

  @override
  String get overrideDefaultLlmSubtitle =>
      'Bestimmtes Modell/Anbieter für diese Aufgabe verwenden';

  @override
  String get provider => 'Anbieter';

  @override
  String get model => 'Modell';

  @override
  String get modelHint => 'z. B. gpt-4o, gemini-2.5-flash';

  @override
  String get apiKey => 'API-Schlüssel';

  @override
  String get apiKeyHint => 'sk-...';

  @override
  String get apiKeyNotSet => 'Nicht gesetzt';

  @override
  String get baseUrl => 'Basis-URL';

  @override
  String get baseUrlHint => 'http://localhost:11434 (für Ollama)';

  @override
  String get temperature => 'Temperatur';

  @override
  String get maxTokens => 'Max. Token';

  @override
  String get mcpServers => 'MCP-Server';

  @override
  String get addServer => 'Server hinzufügen';

  @override
  String get editMcpServer => 'MCP-Server bearbeiten';

  @override
  String get addMcpServer => 'MCP-Server hinzufügen';

  @override
  String get noMcpServers => 'Keine MCP-Server konfiguriert';

  @override
  String get noMcpServersSubtitle =>
      'Füge einen Server hinzu, um externe Tools zu nutzen';

  @override
  String get discoverTools => 'Tools entdecken';

  @override
  String get specUrl => 'Spec-URL';

  @override
  String get apiPassword => 'API-Passwort';

  @override
  String get serverUrl => 'Server-URL *';

  @override
  String get serverUrlHint => 'https://example.com/myserver';

  @override
  String get urlRequired => 'URL ist erforderlich';

  @override
  String get mcpEndpoint => 'MCP-Endpunkt';

  @override
  String get mcpEndpointHint => '/mcp';

  @override
  String get mcpEndpointHelper => 'JSON-RPC-Endpunktpfad (Standard: /mcp)';

  @override
  String get specificationUrl => 'Spezifikations-URL';

  @override
  String get specificationUrlHint =>
      'Optional: OpenAPI/MCP-Spezifikationsendpunkt';

  @override
  String get serverName => 'Name';

  @override
  String get serverNameHint => 'Mein MCP-Server';

  @override
  String get optional => 'Optional';

  @override
  String get enabledTools => 'Aktivierte Tools:';

  @override
  String get discovered => 'Entdeckt:';

  @override
  String toolsCount(int count) {
    return 'Tools ($count)';
  }

  @override
  String promptsCount(int count) {
    return 'Prompts ($count)';
  }

  @override
  String resourcesCount(int count) {
    return 'Ressourcen ($count)';
  }

  @override
  String toolsChip(int count) {
    return '$count Tools';
  }

  @override
  String get builtInMcpServers => 'Integrierte MCP-Server';

  @override
  String get builtInMcpSubtitle =>
      'Interne Tools, die lokal in der App laufen — kein externer Server nötig.';

  @override
  String get addToTask => 'Zur Aufgabe hinzufügen';

  @override
  String get tapToEnable => 'Tippe, um dieses integrierte MCP zu aktivieren';

  @override
  String typeLabel(String type) {
    return 'Typ: $type';
  }

  @override
  String get configuration => 'Konfiguration';

  @override
  String get mcpSystemPrompt => 'System-Prompt';

  @override
  String get mcpSystemPromptHelper =>
      'Weist das LLM an, die Tools dieses MCPs effektiv zu nutzen.';

  @override
  String get mcpSystemPromptHint => 'System-Prompt eingeben…';

  @override
  String get resetToDefault => 'Auf Standard zurücksetzen';

  @override
  String get appendMainSystemPrompt => 'Haupt-System-Prompt anhängen';

  @override
  String get mainSystemPromptAppended => 'Haupt-System-Prompt angehängt';

  @override
  String get noMainSystemPrompt =>
      'Kein Haupt-System-Prompt für diese Aufgabe gesetzt';

  @override
  String get availableTools => 'Verfügbare Tools';

  @override
  String get noBuiltInMcp => 'Keine integrierten MCP-Server verfügbar.';

  @override
  String get globalMcpServersNote =>
      'Diese Server sind global in den Extern-Tools-Einstellungen konfiguriert und stehen dieser Aufgabe immer zur Verfügung.';

  @override
  String get noGlobalMcpServers =>
      'Keine externen MCP-Server konfiguriert. In den Extern-Tools-Einstellungen hinzufügen.';

  @override
  String defaultPrefix(String value) {
    return 'Standard: $value';
  }

  @override
  String get dataSources => 'Datenquellen';

  @override
  String get dataSourcesSubtitle =>
      'Datenquellen für diese Aufgabe aktivieren oder deaktivieren. Zugangsdaten werden global in den Datenquellen-Einstellungen auf dem Startbildschirm konfiguriert.';

  @override
  String get dataSourcesGlobalSubtitle =>
      'Globale Zugangsdaten für Datenquellen konfigurieren. Diese werden sicher auf Ihrem Gerät gespeichert.';

  @override
  String get dataSourcesNotConfiguredHint =>
      'Nicht konfiguriert – in Datenquellen auf dem Startbildschirm einrichten';

  @override
  String get dataSourcesConfiguredHint => 'Zugangsdaten global konfiguriert';

  @override
  String get dataSourcesSettingsSaved =>
      'Datenquellen-Einstellungen gespeichert';

  @override
  String dataSourcesSettingsSaveFailed(String error) {
    return 'Speichern fehlgeschlagen: $error';
  }

  @override
  String get dataSourcesSettingsCleared =>
      'Alle Datenquellen-Einstellungen gelöscht';

  @override
  String get dataSourcesClearTitle =>
      'Alle Datenquellen-Einstellungen löschen?';

  @override
  String get dataSourcesClearMessage =>
      'Alle gespeicherten Zugangsdaten werden entfernt. Datenquellen müssen neu konfiguriert werden.';

  @override
  String dataSourcesConfigured(int count) {
    return '$count Datenquelle(n) konfiguriert';
  }

  @override
  String get dataSourcesNone => 'Keine Datenquellen konfiguriert';

  @override
  String get emailProvider => 'E-Mail-Anbieter';

  @override
  String get emailProviderSubtitle =>
      'E-Mails lesen, suchen und Benachrichtigungen senden';

  @override
  String get imapProvider => 'IMAP (allgemein)';

  @override
  String get imapHost => 'IMAP-Host (eingehend)';

  @override
  String get imapHostHint => 'imap.beispiel.de';

  @override
  String get imapPort => 'Port';

  @override
  String get imapUsername => 'Benutzername';

  @override
  String get imapPassword => 'Passwort';

  @override
  String get imapUseSsl => 'SSL/TLS verwenden';

  @override
  String get smtpHost => 'SMTP-Host (ausgehend)';

  @override
  String get smtpHostHint => 'smtp.beispiel.de';

  @override
  String get smtpPort => 'SMTP-Port';

  @override
  String get smtpSender => 'Absender E-Mail';

  @override
  String get smtpSenderHint => 'ihre-email@beispiel.de';

  @override
  String get notificationEmail => 'Für Aufgaben-Benachrichtigungen verwenden';

  @override
  String get notificationEmailHint => 'Aufgabenergebnisse per E-Mail senden';

  @override
  String get googleServices => 'Google-Dienste';

  @override
  String get googleServicesSubtitle => 'Gmail-Suche und Google Drive-Zugriff';

  @override
  String get imapSmtpEmail => 'E-Mail-Versand (SMTP)';

  @override
  String get imapSmtpEmailSubtitle => 'E-Mails über externen Mailserver senden';

  @override
  String get cloudStorage => 'Cloud-Speicher';

  @override
  String get cloudStorageSubtitle =>
      'Dateien von Google Drive oder OneDrive abrufen';

  @override
  String get googleDrive => 'Google Drive';

  @override
  String get oneDrive => 'Microsoft OneDrive';

  @override
  String get oneDriveSubtitle => 'Auf Dateien aus Microsoft OneDrive zugreifen';

  @override
  String get oneDriveClientId => 'Anwendungs-ID (Client-ID)';

  @override
  String get oneDriveClientIdHint => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';

  @override
  String get oneDriveTenantId => 'Verzeichnis-ID (Mandanten-ID)';

  @override
  String get oneDriveTenantIdHint => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';

  @override
  String get gmail => 'Google Mail (Gmail)';

  @override
  String get gmailSubtitle => 'E-Mails über die Gmail API mit OAuth2 lesen';

  @override
  String get gmailSetup =>
      'Du benötigst ein Google Cloud-Projekt mit aktivierter Gmail API und OAuth2-Anmeldedaten (Desktop-App-Typ).';

  @override
  String get oauthClientId => 'OAuth2 Client-ID *';

  @override
  String get oauthClientIdHint => '123456-abc.apps.googleusercontent.com';

  @override
  String get oauthClientSecret => 'OAuth2 Client-Geheimnis *';

  @override
  String get oauthClientSecretHint => 'GOCSPX-...';

  @override
  String get authorizeGoogle => 'Mit Google autorisieren';

  @override
  String get oauthAuthorizationCode => 'Autorisierungscode';

  @override
  String get oauthAuthorizationCodeHint =>
      'Code oder vollständige Callback-URL einfügen (http://localhost/?code=...)';

  @override
  String get exchangeAuthorizationCode => 'Code austauschen';

  @override
  String get oauthOpenSuccess =>
      'Google-Zustimmung geöffnet. Nach dem Login den code=... aus der Browser-URL kopieren oder die vollständige Callback-URL hier einfügen.';

  @override
  String get oauthOpenFailed =>
      'Google-Zustimmungsbildschirm konnte nicht geöffnet werden.';

  @override
  String get oauthCodeRequired => 'Autorisierungscode ist erforderlich.';

  @override
  String get oauthExchangeSuccess => 'Google OAuth erfolgreich verbunden.';

  @override
  String oauthExchangeFailed(String error) {
    return 'Google OAuth-Austausch fehlgeschlagen: $error';
  }

  @override
  String oauthTokenStatusReady(String email, String expiry) {
    return 'OAuth verbunden für $email, Token läuft ab um $expiry';
  }

  @override
  String get oauthTokenStatusMissing => 'OAuth-Token noch nicht verbunden.';

  @override
  String get sendTestEmail => 'Test-E-Mail senden';

  @override
  String get testEmailRecipient => 'Test-Empfänger';

  @override
  String get testEmailRecipientRequired =>
      'Test-Empfänger-E-Mail ist erforderlich.';

  @override
  String get testEmailSent => 'Test-E-Mail erfolgreich gesendet.';

  @override
  String testEmailFailed(String error) {
    return 'Test-E-Mail fehlgeschlagen: $error';
  }

  @override
  String get oauthNotYet =>
      'OAuth2-Ablauf noch nicht implementiert — speichere zuerst die Anmeldedaten';

  @override
  String get na => 'k. A.';

  @override
  String get webSearch => 'Websuche';

  @override
  String get webSearchSubtitle => 'Im Web über Google oder DuckDuckGo suchen';

  @override
  String get searchProvider => 'Suchanbieter';

  @override
  String get customProvider => 'Benutzerdefinierter Anbieter';

  @override
  String get customProviderSetup => 'Benutzerdefinierte Anbieterkonfiguration';

  @override
  String get customProviderName => 'Anbietername';

  @override
  String get customProviderNameHint => 'z. B. Internal Search API';

  @override
  String get customProviderEndpoint => 'Anbieter-Endpunkt-URL';

  @override
  String get customProviderEndpointHint => 'https://example.com/search';

  @override
  String get serperProvider => 'Serper.dev';

  @override
  String get serperSetup => 'Serper.dev-Einrichtung';

  @override
  String get serperApiKeyHint => 'serper_... oder Ihr API-Schlüssel';

  @override
  String get serpApiProvider => 'SerpApi (Google-Suche)';

  @override
  String get serpApiSetup =>
      'SerpApi verwendet die Google Search API. Benötigt einen API-Schlüssel von serpapi.com.';

  @override
  String get serpApiKeyHint => 'Ihr SerpApi API-Schlüssel';

  @override
  String get duckDuckGo => 'DuckDuckGo (kein API-Schlüssel nötig)';

  @override
  String get googleCustomSearch => 'Google Custom Search';

  @override
  String get googleSearchSetup =>
      'Benötigt einen Google Cloud API-Schlüssel und eine Programmable Search Engine-ID (CSE).';

  @override
  String get searchEngineId => 'Suchmaschinen-ID *';

  @override
  String get searchEngineIdHint => 'a1b2c3d4e5f...';

  @override
  String get maxResults => 'Max. Ergebnisse';

  @override
  String get testSearchQuery => 'Test-Suchanfrage';

  @override
  String get testSearchQueryHint => 'z.B. Flutter aktuelle Nachrichten';

  @override
  String get testSearch => 'Suche testen';

  @override
  String testSearchSuccess(int count, String provider) {
    return 'Suche erfolgreich — $count Ergebnisse von $provider.';
  }

  @override
  String testSearchFailed(String error) {
    return 'Suchtest fehlgeschlagen: $error';
  }

  @override
  String get testDriveConnection => 'Verbindung testen';

  @override
  String testDriveSuccess(int count) {
    return 'Verbunden — $count Elemente im Stammordner gefunden.';
  }

  @override
  String testDriveFailed(String error) {
    return 'Drive-Test fehlgeschlagen: $error';
  }

  @override
  String get serverLoadingSettingsTitle => 'Einstellungen werden geladen...';

  @override
  String get serverLoadingSettingsBody =>
      'Server-Einstellungen werden in die App geladen. Bitte warten.';

  @override
  String get serverSwitchTitle => 'Zu Server-Modus wechseln';

  @override
  String get serverSwitchBody =>
      'Du wechselst in den Server-Modus. Agenten, Zeitpläne und Einstellungen verwenden die Remote-Server-Datenbank. Die lokale Datenbank bleibt getrennt und wird nicht synchronisiert.';

  @override
  String get serverSwitchAction => 'Wechseln';

  @override
  String get serverConnected => 'Mit Server verbunden!';

  @override
  String get serverConnectionFailed =>
      'Verbindung fehlgeschlagen — Server-URL und API-Key-Autorisierung prüfen.';

  @override
  String get serverNotReachable => 'Server nicht erreichbar.';

  @override
  String get serverReachableAuthorized =>
      'Server erreichbar und Autorisierung gültig.';

  @override
  String get serverReachableUnauthorized =>
      'Server erreichbar, aber API-Key-Autorisierung fehlgeschlagen.';

  @override
  String get serverSettingsTitle => 'Server-Modus-Einstellungen';

  @override
  String serverSettingsError(String error) {
    return 'Fehler: $error';
  }

  @override
  String get serverSettingsUrlLabel => 'Server-URL';

  @override
  String get serverSettingsUrlHint => 'http://192.168.1.100:7771';

  @override
  String get serverSettingsUrlHelper =>
      'Port angeben; kein abschließender Schrägstrich';

  @override
  String get serverSettingsUrlInvalid => 'Gib eine gültige URL ein';

  @override
  String get serverTestConnectionButton => 'Verbindung testen';

  @override
  String get serverConnecting => 'Verbinde...';

  @override
  String get serverConnectUseRemote => 'Verbinden & Remote nutzen';

  @override
  String get serverAboutTitle => 'Über den Server-Modus';

  @override
  String get serverAboutBody =>
      'Der Server-Modus verbindet diese App mit einer TealKit-Server-Instanz auf Ihrem Heimserver, NAS oder Raspberry Pi.\n\nAufgabendaten werden vom Remote-Server gelesen und geschrieben. Die Zeitplanausführung erfolgt ebenfalls auf dem Server — die App muss nicht geöffnet sein.';

  @override
  String get serverApiKeyTitle => 'Server-API-Key';

  @override
  String get serverApiKeyBody =>
      'Diese App hat einen eindeutigen API-Key automatisch generiert. Konfiguriere deinen TealKit-Server damit, sodass nur diese App eine Verbindung herstellen kann.';

  @override
  String get serverCopyFullKeyTooltip => 'Vollständigen Key kopieren';

  @override
  String get serverApiKeyCopied => 'API-Key in die Zwischenablage kopiert';

  @override
  String get serverApiKeyEnvHint =>
      'Als Umgebungsvariable beim Serverstart setzen:\ndocker run -e TEALKIT_API_KEY=<key> ...';

  @override
  String get emailNotification => 'E-Mail-Benachrichtigung';

  @override
  String get sendEmailAfterTask => 'E-Mail nach Aufgabenausführung senden';

  @override
  String get toEmail => 'An (E-Mail)';

  @override
  String get toEmailHint => 'benutzer@example.com';

  @override
  String get subject => 'Betreff';

  @override
  String get subjectHint => 'Aufgabenergebnis: [task_name]';

  @override
  String get sendCondition => 'Sendebedingung';

  @override
  String get always => 'Immer';

  @override
  String get onSuccess => 'Bei Erfolg';

  @override
  String get onFailure => 'Bei Fehler';

  @override
  String get onResultChange => 'Bei Ergebnisänderung';

  @override
  String get outputType => 'Ausgabetyp';

  @override
  String get outputTypeEmail => 'E-Mail';

  @override
  String get outputTypeFile => 'Datei';

  @override
  String get outputTypeSftp => 'SFTP-Upload';

  @override
  String get sftpUseConfiguredSshServer =>
      'Konfigurierten SSH-Server verwenden';

  @override
  String get sftpHost => 'SFTP-Host';

  @override
  String get sftpPort => 'Port';

  @override
  String get sftpUsername => 'Benutzername';

  @override
  String get sftpPassword => 'Passwort';

  @override
  String get sftpRemotePath => 'Standardordner (Remotepfad)';

  @override
  String get sftpRemotePathHint => 'z. B. /uploads/tealkit';

  @override
  String get sftpNotifyByEmail => 'Benachrichtigungs-E-Mail nach Upload senden';

  @override
  String get sftpNotifyEmailAddress => 'Benachrichtigungs-E-Mail-Adresse';

  @override
  String get sftpNotifyEmailSubject => 'Betreff';

  @override
  String get sftpNotifyEmailBody => 'Text (leer lassen für Standardvorlage)';

  @override
  String get sftpNotifyEmailBodyHint => 'Leer lassen für automatischen Text';

  @override
  String get outputDirectory => 'Ausgabeverzeichnis';

  @override
  String get outputDirectoryHint =>
      'Wähle, wo erzeugte Dateien gespeichert werden';

  @override
  String get outputDirectoryNote =>
      'Die Verzeichnisauswahl hängt von Plattformberechtigungen ab.';

  @override
  String get outputFolderRequired =>
      'Für den Ausgabetyp \"Datei\" muss ein Ausgabeordner ausgewählt werden. Tippen Sie auf das Ordnersymbol.';

  @override
  String get chooseDirectory => 'Verzeichnis wählen';

  @override
  String get fileNamePattern => 'Dateinamenmuster';

  @override
  String fileNamePatternHint(Object date) {
    return 'task_result_$date.txt';
  }

  @override
  String get addExecutionLogToOutput =>
      'Ausführungsprotokoll zur Ausgabe hinzufügen';

  @override
  String get zipOutputFiles => 'Ausgabedateien zippen';

  @override
  String get runningTaskWithDuckdb =>
      'Aufgabe läuft und indiziert/sucht mit DuckDB...';

  @override
  String get openLatestFile => 'Neueste Datei öffnen';

  @override
  String get pathNotFound => 'Pfad nicht gefunden';

  @override
  String openFailed(String error) {
    return 'Öffnen fehlgeschlagen: $error';
  }

  @override
  String get localSearchIndexDuckdb => 'Lokaler Suchindex (DuckDB)';

  @override
  String get duckdbSizeLimitDescription =>
      'Maximale indexierte Datenmenge in GB. Die Indexierung stoppt, wenn das Limit erreicht ist.';

  @override
  String get duckdbSizeLimitGb => 'DuckDB-Limit (GB)';

  @override
  String get duckdbSizeLimitHint => '1.0';

  @override
  String get pushNotification => 'Push-Benachrichtigung';

  @override
  String get sendPush => 'Push-Benachrichtigung senden';

  @override
  String get title => 'Titel';

  @override
  String get titleHint => 'Aufgabe abgeschlossen';

  @override
  String get deviceToken => 'Geräte-Token';

  @override
  String get noTasksYet => 'Noch keine Workflows';

  @override
  String get createScheduledTask =>
      'Erstelle einen geplanten Workflow für deinen KI-Assistenten';

  @override
  String get browseExamples => 'Beispiele durchsuchen';

  @override
  String get browseExamplesTooltip => 'Vordefinierte Beispielaufgabe auswählen';

  @override
  String get orStartFromExample => 'oder mit einem Beispiel starten';

  @override
  String get initialMessage => 'Erste Nachricht';

  @override
  String get fieldRequired => 'Dieses Feld ist erforderlich';

  @override
  String get invalidEmail => 'Gib eine gültige E-Mail-Adresse ein';

  @override
  String get searchTasks => 'Workflows suchen...';

  @override
  String get noMatchingTasks => 'Keine passenden Workflows gefunden';

  @override
  String lastRun(String date) {
    return 'Zuletzt: $date';
  }

  @override
  String nextRun(String date) {
    return 'Nächste: $date';
  }

  @override
  String get never => 'Nie';

  @override
  String get columnActions => 'Aktionen';

  @override
  String get columnName => 'Name';

  @override
  String get columnUpdated => 'Aktualisiert';

  @override
  String get columnPrompt => 'Prompt';

  @override
  String get columnSchedule => 'Zeitplan';

  @override
  String get columnStatus => 'Status';

  @override
  String get columnEnabled => 'Aktiviert';

  @override
  String get columnLastRun => 'Letzter Lauf';

  @override
  String get costLastShort => 'Zuletzt';

  @override
  String get costTotalShort => 'Gesamt';

  @override
  String get executeNow => 'Jetzt ausführen';

  @override
  String get taskRunSuccess => 'Workflow erfolgreich ausgeführt';

  @override
  String get taskRunFailed => 'Workflow-Ausführung mit Fehlern beendet';

  @override
  String taskRunError(String error) {
    return 'Workflow-Ausführung fehlgeschlagen: $error';
  }

  @override
  String get statusDisabled => 'Deaktiviert';

  @override
  String get statusFailed => 'Fehlgeschlagen';

  @override
  String statusFailedCount(int count) {
    return 'Fehlgeschlagen ($count in Folge)';
  }

  @override
  String statusOk(int count) {
    return 'OK — $count Läufe';
  }

  @override
  String get statusPending => 'Ausstehend';

  @override
  String get statusPendingNeverRun => 'Ausstehend — nie ausgeführt';

  @override
  String get detailGeneral => 'Allgemein';

  @override
  String get detailName => 'Name';

  @override
  String get detailDescription => 'Beschreibung';

  @override
  String get detailAgentId => 'Agent-ID';

  @override
  String get detailEnabled => 'Aktiviert';

  @override
  String get detailTags => 'Tags';

  @override
  String get detailCreated => 'Erstellt';

  @override
  String get detailUpdated => 'Aktualisiert';

  @override
  String get detailPrompts => 'Prompts';

  @override
  String get detailSystemPrompt => 'System-Prompt';

  @override
  String get detailPrompt => 'Prompt';

  @override
  String get detailSchedule => 'Zeitplan';

  @override
  String get detailCron => 'Cron';

  @override
  String get detailHint => 'Hinweis';

  @override
  String get detailMaxRetries => 'Max. Wiederholungen';

  @override
  String get detailRetryOnFailure => 'Bei Fehler wiederholen';

  @override
  String get detailRetryDelay => 'Wiederholungsverzögerung';

  @override
  String detailRetryDelayValue(int minutes) {
    return '$minutes Min.';
  }

  @override
  String get detailExecuteImmediately => 'Sofort ausführen';

  @override
  String get detailLlmOverride => 'LLM-Konfiguration';

  @override
  String get detailProvider => 'Anbieter';

  @override
  String get detailModel => 'Modell';

  @override
  String get detailBaseUrl => 'Basis-URL';

  @override
  String get detailTemperature => 'Temperatur';

  @override
  String get detailMaxTokens => 'Max. Token';

  @override
  String get detailApiKey => 'API-Schlüssel';

  @override
  String detailBuiltInTools(int count) {
    return 'Integrierte Tools ($count)';
  }

  @override
  String detailMcpTools(int count) {
    return 'MCP-Tools ($count)';
  }

  @override
  String get detailProviders => 'Anbieter';

  @override
  String get detailEmail => 'E-Mail';

  @override
  String get detailWebSearch => 'Websuche';

  @override
  String get detailNotifications => 'Benachrichtigungen';

  @override
  String get detailEmailTo => 'E-Mail an';

  @override
  String get detailSubject => 'Betreff';

  @override
  String get detailSendWhen => 'Senden bei';

  @override
  String get detailPush => 'Push';

  @override
  String get detailPushTitle => 'Push-Titel';

  @override
  String get detailDownload => 'Download';

  @override
  String get detailDefaultDownloads => 'Standard-Downloads';

  @override
  String get detailUpload => 'Upload';

  @override
  String get detailTotalRuns => 'Gesamtläufe';

  @override
  String get detailConsecutiveFailures => 'Fehler in Folge';

  @override
  String get detailLastRun => 'Letzter Lauf';

  @override
  String get detailNextRun => 'Nächster Lauf';

  @override
  String get detailLastResult => 'Letztes Ergebnis';

  @override
  String get detailLastError => 'Letzter Fehler';

  @override
  String get userLog => 'Benutzerprotokoll';

  @override
  String get executionLog => 'Ausführungsprotokoll';

  @override
  String get generatedFiles => 'Erzeugte Dateien';

  @override
  String detailRunHistory(int count) {
    return 'Laufhistorie ($count)';
  }

  @override
  String detailDuration(int ms) {
    return 'Dauer: $ms ms';
  }

  @override
  String get detailDurationNA => 'Dauer: k. A.';

  @override
  String get unknownError => 'Unbekannter Fehler';

  @override
  String get viewResult => 'Ergebnis anzeigen';

  @override
  String runDate(String date) {
    return 'Lauf $date';
  }

  @override
  String get result => 'Ergebnis:';

  @override
  String get error => 'Fehler:';

  @override
  String get configured => 'konfiguriert';

  @override
  String get allTools => 'alle';

  @override
  String webSearchMaxResults(int count) {
    return 'max. $count';
  }

  @override
  String get weatherSystemPrompt =>
      'Du bist ein Wetterassistent. Nutze die Wetter-Tools, um Fragen zu aktuellen Bedingungen, Stunden- und Tagesprognosen zu beantworten. Gib immer Temperatur, Windgeschwindigkeit und Niederschlagswahrscheinlichkeit an. Wenn der Nutzer eine Stadt erwähnt, führe zuerst die Geokodierung durch und rufe dann die Wetterdaten ab. Präsentiere die Ergebnisse knapp mit Einheiten (°C, km/h, %). Wenn kein Standort angegeben ist, verwende den konfigurierten Standard.';

  @override
  String get weatherDisplayName => 'Wetter';

  @override
  String get weatherDescription =>
      'Wettervorhersagen über Open-Meteo abrufen (kostenlos, kein API-Schlüssel). Bietet aktuelle Bedingungen, Stunden- und Tagesprognosen.';

  @override
  String get documentDisplayName => 'Dokumentensuche';

  @override
  String get documentDescription =>
      'Lokale Dokumente durchsuchen und indexieren (TXT, MD, DOCX, XLSX, PDF, CSV). Extrahiert Textinhalte und bietet Volltextsuche über DuckDB.';

  @override
  String get documentSystemPrompt =>
      'Du bist ein Dokumenten-Suchassistent. Nutze die Dokument-Tools, um lokale Dokumente zu finden und zu durchsuchen. Wenn der Nutzer nach Dokumenteninhalten fragt, verwende search_documents um relevante Dateien zu finden und dann get_document_content um bestimmte Dokumente zu lesen. Präsentiere Ergebnisse klar mit Dateinamen und relevanten Auszügen. Falls keine Treffer gefunden werden, schlage breitere Suchbegriffe vor.';

  @override
  String get reindexDocuments => 'Dokumente neu indexieren';

  @override
  String get reindexDocumentsHint =>
      'Ordner erneut scannen und Suchindex neu aufbauen.';

  @override
  String get reindexing => 'Dokumente werden indexiert…';

  @override
  String reindexComplete(
    int count,
    int ms,
    String fileSizeKb,
    String indexSizeKb,
  ) {
    return 'Indexierung abgeschlossen: $count Dokumente in $ms ms (Dateien: $fileSizeKb KB, Index: $indexSizeKb KB)';
  }

  @override
  String reindexFailed(String error) {
    return 'Indexierung fehlgeschlagen: $error';
  }

  @override
  String get indexingStart => 'Indexierung starten';

  @override
  String get indexingStop => 'Stopp';

  @override
  String indexingProgress(int current, int total) {
    return 'Indexierung: $current/$total';
  }

  @override
  String indexingCurrentFile(String fileName) {
    return 'Aktuell: $fileName';
  }

  @override
  String indexingCancelled(int count) {
    return 'Indexierung abgebrochen nach $count Dokumenten';
  }

  @override
  String get indexingStrategyNow => 'Jetzt indexieren (bei Initialisierung)';

  @override
  String get indexingStrategyLazy => 'Vor erster Suche indexieren';

  @override
  String get indexEachTime => 'Bei jedem Agentenlauf indexieren';

  @override
  String get indexFirstTime => 'Nur beim ersten Mal indexieren';

  @override
  String get paramLabelRootPath => 'Stammverzeichnis';

  @override
  String get paramLabelFileTypes => 'Dateitypen';

  @override
  String get paramLabelIndexingStrategy => 'Indexierungsstrategie';

  @override
  String get paramLabelMaxDocuments => 'Max. Dokumente';

  @override
  String get paramLabelWebsiteUrls => 'Website-URLs';

  @override
  String get paramLabelMaxPages => 'Max. Seiten';

  @override
  String get paramLabelMaxResults => 'Max. Ergebnisse';

  @override
  String get paramLabelAccessToken => 'Access-Token';

  @override
  String get paramLabelUserId => 'Benutzer-ID';

  @override
  String get enumAuto => 'Automatisch';

  @override
  String get llmSettings => 'LLM-Einstellungen';

  @override
  String get llmSettingsSubtitle => 'KI-Anbieter & Modell konfigurieren';

  @override
  String get llmSettingsInfo =>
      'Konfigurieren Sie hier Ihren Standard-LLM-Anbieter. Diese Einstellungen werden sicher auf Ihrem Gerät gespeichert und können automatisch beim Erstellen neuer Aufgaben übernommen werden.';

  @override
  String get llmSettingsSaved => 'LLM-Einstellungen gespeichert';

  @override
  String llmSettingsSaveFailed(String error) {
    return 'LLM-Einstellungen konnten nicht gespeichert werden: $error';
  }

  @override
  String get llmSettingsCleared => 'LLM-Einstellungen gelöscht';

  @override
  String get llmClearSettingsTitle => 'LLM-Einstellungen löschen';

  @override
  String get llmClearSettingsMessage =>
      'Dadurch werden alle gespeicherten LLM-Zugangsdaten und Konfigurationen entfernt. Sind Sie sicher?';

  @override
  String get llmProviderLabel => 'Anbieter';

  @override
  String get llmModelLabel => 'Modell';

  @override
  String get llmModelHint => 'z.B. gemini-2.5-flash';

  @override
  String get llmModelRequired => 'Modellname ist erforderlich';

  @override
  String get llmApiKeyLabel => 'API-Schlüssel';

  @override
  String get llmApiKeyRequired =>
      'API-Schlüssel ist für diesen Anbieter erforderlich';

  @override
  String get llmApiKeyOptional => 'API-Schlüssel (optional)';

  @override
  String get llmBaseUrlLabel => 'Basis-URL';

  @override
  String get llmBaseUrlRequired =>
      'Basis-URL ist für diesen Anbieter erforderlich';

  @override
  String get llmUseNativeToolCall => 'Native Werkzeugaufrufe nutzen';

  @override
  String get llmUseNativeToolCallDescription =>
      'Nutzt die nativen Tool-Call-Fähigkeiten von Ollama, anstatt Tools als Text in den Prompt einzufügen.';

  @override
  String get llmUseSafeToolCall => 'Sicherer Werkzeugaufruf-Modus';

  @override
  String get llmUseSafeToolCallDescription =>
      'Nutzt grammatik-beschränkte Dekodierung, um fehlerhafte Werkzeugaufrufe zu verhindern. Funktioniert auch für Modelle ohne nativen Werkzeugaufruf.';

  @override
  String get llmAdvancedSettings => 'Erweiterte Einstellungen';

  @override
  String get llmTemperatureRange => 'Muss zwischen 0,0 und 2,0 liegen';

  @override
  String get llmMaxTokensRange => 'Muss eine positive Zahl sein';

  @override
  String llmConfiguredStatus(String provider, String model) {
    return 'Konfiguriert: $provider / $model';
  }

  @override
  String get llmNotConfigured => 'Nicht konfiguriert';

  @override
  String get llmApplyDefaults => 'Standard-LLM-Einstellungen anwenden';

  @override
  String get llmApplyDefaultsSubtitle =>
      'Felder unten mit Ihren gespeicherten LLM-Einstellungen füllen';

  @override
  String get llmDefaultsApplied => 'Standard-LLM-Einstellungen angewendet';

  @override
  String get llmNoDefaults =>
      'Keine Standard-LLM-Einstellungen konfiguriert. Öffnen Sie zuerst die LLM-Einstellungen auf dem Startbildschirm.';

  @override
  String get llmAdvancedParams => 'Erweiterte Parameter';

  @override
  String get topK => 'Top K';

  @override
  String get topKTooltip =>
      'Begrenzt Vokabular auf Top-K-Token. Niedriger = deterministischer. Bereich: 1–100.';

  @override
  String get topP => 'Top P';

  @override
  String get topPTooltip =>
      'Nucleus-Sampling-Grenzwert. Niedriger = fokussiertere Ausgabe. Bereich: 0,0–1,0.';

  @override
  String get repeatPenalty => 'Wiederholungsstrafe';

  @override
  String get repeatPenaltyTooltip =>
      'Bestraft Wiederholungen (>1,0 reduziert Wiederholungen). Bereich: 0,5–2,0.';

  @override
  String get seed => 'Seed';

  @override
  String get seedTooltip =>
      'Zufalls-Seed für reproduzierbare Ausgaben. Leer lassen für zufällig.';

  @override
  String get llm2EditableSettings =>
      'LLM 2 Einstellungen (für diese Aufgabe änderbar)';

  @override
  String get llm2SettingsOverrideHint =>
      'Aus globalen LLM 2 Einstellungen vorbelegt. Änderungen gelten nur für diese Aufgabe.';

  @override
  String get interactiveMode => 'Interaktiv';

  @override
  String get interactiveModeTooltip => 'Diese Aufgabe interaktiv testen';

  @override
  String get interactiveModeTitle => 'Interaktiver Modus';

  @override
  String get interactiveNoLlm =>
      'Kein LLM konfiguriert. Bitte zuerst LLM-Einstellungen konfigurieren.';

  @override
  String get interactiveConnecting =>
      'Verbindung zu MCP-Servern wird hergestellt…';

  @override
  String get interactiveReady =>
      'Bereit — geben Sie eine Nachricht ein, um diese Aufgabe zu testen';

  @override
  String get interactiveSystemPromptLocked =>
      'System-Prompt aus Aufgabenkonfiguration gesperrt';

  @override
  String interactiveToolsAvailable(int count) {
    return '$count Tools verfügbar';
  }

  @override
  String get interactiveNoTools => 'Keine Tools konfiguriert';

  @override
  String get interactiveDisconnect => 'Trennen & Schließen';

  @override
  String get sectionRawOutput => 'Rohausgabe';

  @override
  String get sectionOutputUser => 'Benutzerausgabe';

  @override
  String get sectionOutputFiles => 'Ausgabedateien';

  @override
  String get sectionSchedulerLog => 'Planer-Protokoll';

  @override
  String get noRawOutput =>
      'Keine Rohausgabe für den letzten Lauf aufgezeichnet';

  @override
  String get noOutputUser => 'Keine Benutzerausgabe aufgezeichnet';

  @override
  String get noOutputFiles => 'Keine Ausgabedateien gefunden';

  @override
  String get noSchedulerLog => 'Keine Planer-Ereignisse aufgezeichnet';

  @override
  String get schedulerEventScheduled => 'Geplant';

  @override
  String get schedulerEventFired => 'Ausgelöst';

  @override
  String get schedulerEventStarted => 'Gestartet';

  @override
  String get schedulerEventCompleted => 'Abgeschlossen';

  @override
  String get schedulerEventFailed => 'Fehlgeschlagen';

  @override
  String get schedulerEventSkipped => 'Übersprungen';

  @override
  String get schedulerEventAlarm => 'Alarm';

  @override
  String get schedulerActivity => 'Hintergrundaktivität';

  @override
  String get schedulerActivityTitle => 'Hintergrundaktivität · Letzte 48 Std.';

  @override
  String outputFileRunDir(String date) {
    return 'Lauf $date';
  }

  @override
  String get daysToLive => 'Tage für Ausgabedateien aufbewahren';

  @override
  String get copyToClipboard => 'In Zwischenablage kopieren';

  @override
  String get copiedToClipboard => 'In Zwischenablage kopiert';

  @override
  String schedulerLogDetail(String detail) {
    return 'Detail: $detail';
  }

  @override
  String get tabChaining => 'Verkettung';

  @override
  String get chainThisTaskSection => 'Dieser Agent';

  @override
  String get chainIsSubtask => 'Folgeagent-Modus';

  @override
  String get chainIsSubtaskHint =>
      'Nur ausführen, wenn von einem anderen Agenten ausgelöst — Scheduler wird ignoriert';

  @override
  String get chainSubtaskHint =>
      'Tipp: Verwende [task_result] im Prompt dieses Agenten, um die Ausgabe des auslösenden Agenten einzufügen.';

  @override
  String get chainTriggerSection => 'Folgeagenten auslösen';

  @override
  String get chainTriggerSectionHint =>
      'Nach Abschluss dieses Agenten optional einen weiteren Agenten anhand einer LLM-Bedingung ausführen.';

  @override
  String get chainWithCondition => 'Mit Bedingung';

  @override
  String get chainWithConditionHint =>
      'Eine LLM-Bedingung auswerten, um zwischen zwei Folgeagenten zu wählen.';

  @override
  String get chainDirectFollowup => 'Folgeagent (ohne Bedingung)';

  @override
  String get chainDirectFollowupHint =>
      'Diesen Agenten nach Abschluss immer auslösen und [task_result] weitergeben.';

  @override
  String get stopAfterToolCall => 'Nach Tool-Aufruf stoppen';

  @override
  String get stopAfterToolCallHint =>
      'Tool-Aufruf ausführen, aber das Ergebnis nicht an das LLM zurücksenden. Die Tool-Ausgabe wird als [task_result] an den Folgeagenten weitergegeben. Bei mehreren Schritten: Jeder Schritt stoppt nach dem ersten Tool-Aufruf, danach startet der nächste Schritt sofort.';

  @override
  String get chainCondition => 'Bedingung (LLM-Auswertung)';

  @override
  String get chainConditionHint => 'z. B. Temperatur liegt unter 10 Grad';

  @override
  String get chainConditionHelper =>
      'Leer lassen, um die \"bei Übereinstimmung\"- Aufgabe immer auszuführen. [task_result] bezieht sich auf die Ausgabe dieser Aufgabe.';

  @override
  String get chainOnMatch => 'Bei Bedingungserfüllung — Agenten ausführen';

  @override
  String get chainOnNoMatch =>
      'Bei Nicht-Erfüllung — Agenten ausführen (sonst)';

  @override
  String get chainTaskIdHint => 'Agenten-ID...';

  @override
  String get chainPickTask => 'Folgeagenten auswählen';

  @override
  String get chainTaskResultHint =>
      'Schreibe [task_result] im Prompt eines verketteten Agenten, um die Ausgabe dieses Agenten einzufügen.';

  @override
  String get noTasksAvailable => 'Keine Agenten verfügbar';

  @override
  String get noSubtasksAvailable =>
      'Keine Folgeagenten gefunden. Aktiviere zunächst den \'Folgeagent-Modus\' bei einem Agenten.';

  @override
  String get scheduleDisabledSubtask =>
      'Zeitplan inaktiv — dieser Agent läuft als Folgeagent und wird durch einen anderen Agenten gestartet.';

  @override
  String get detailChainConfig => 'Agenten-Verkettung';

  @override
  String get detailChainIsSubtask => 'Folgeagent-Modus';

  @override
  String get detailChainCondition => 'Bedingung';

  @override
  String get detailChainOnMatch => 'Bei Erfüllung → Aufgabe';

  @override
  String get detailChainOnNoMatch => 'Bei Nicht-Erfüllung → Aufgabe';

  @override
  String get wizardLlmDescription =>
      'Anbieter, Modell und API-Schlüssel einrichten. Erforderlich vor dem Ausführen von Aufgaben.';

  @override
  String get wizardOpenLlmSettings => 'LLM-Einstellungen öffnen';

  @override
  String get wizardDataSourcesDescription =>
      'Gmail, IMAP, Websuche und Cloud-Speicher konfigurieren.';

  @override
  String get wizardOpenDataSources => 'Datenquellen öffnen';

  @override
  String get wizardExternalToolsTitle => 'Remote MCP-Server';

  @override
  String get wizardExternalToolsDescription =>
      'Remote MCP-Server konfigurieren, die über HTTPS/SSE erreichbar sind.';

  @override
  String get wizardOpenExternalTools => 'Remote Server öffnen';

  @override
  String get requiredLabel => 'Erforderlich';

  @override
  String get generalSection => 'Allgemein';

  @override
  String get generalSectionDescription =>
      'Theme, Sprache und Backup-Einstellungen.';

  @override
  String get themeLabel => 'Theme';

  @override
  String get themeToggleTooltip => 'Wechseln: Dunkel → System → Hell';

  @override
  String get languageLabel => 'Sprache';

  @override
  String get languageToggleTooltip => 'Sprache wechseln';

  @override
  String get defaultOutputDir => 'Standard-Ausgabeverzeichnis';

  @override
  String get defaultOutputDirDescription =>
      'Ordner, in dem Aufgabenergebnisse, Ausgabe- und Ausführungsprotokolle gespeichert werden.';

  @override
  String get defaultOutputDirNotSet =>
      'Nicht gesetzt – App-Dokumentenordner wird verwendet';

  @override
  String get outputRetentionDays => 'Dateien behalten (Tage)';

  @override
  String get outputRetentionDaysDescription =>
      'Ausgabeordner die älter als dieser Wert sind werden automatisch gelöscht.';

  @override
  String get backgroundCheckInterval => 'Hintergrund-Prüfintervall';

  @override
  String get backgroundCheckIntervalDescription =>
      'Wie oft die App im Hintergrund aufwacht, um geplante Aufgaben zu prüfen. Ein kürzeres Intervall ist reaktionsschneller, verbraucht aber etwas mehr Akku.';

  @override
  String get exportBackup => 'Export';

  @override
  String get exportBackupDescription =>
      'Aufgaben & MCP-Server-Definitionen (ohne API-Schlüssel)';

  @override
  String get importBackup => 'Import';

  @override
  String get importBackupDescription =>
      'Aufgaben & MCP-Server aus einer JSON-Datei wiederherstellen';

  @override
  String exportFailed(String error) {
    return 'Export fehlgeschlagen: $error';
  }

  @override
  String exportSavedToDownloads(String fileName) {
    return 'In Downloads gespeichert: $fileName';
  }

  @override
  String get exportSuccess => 'Backup erfolgreich exportiert';

  @override
  String get phaseConfiguringLlm => 'LLM wird konfiguriert…';

  @override
  String get phaseConnectingExternalMcp => 'Verbinde externe MCP-Server…';

  @override
  String get phaseConnectingInternalMcp => 'Initialisiere integrierte Tools…';

  @override
  String get chatSessionReset =>
      'Chat-Sitzung zurückgesetzt und neu initialisiert';

  @override
  String get filterToolsHint => 'Tools filtern…';

  @override
  String get noActiveTask =>
      'Keine aktive Aufgabe. Bitte zuerst eine Aufgabe auswählen.';

  @override
  String get resetChatSessionTooltip => 'Chat-Sitzung zurücksetzen';

  @override
  String get chatStartHint => 'Nachricht senden, um zu beginnen…';

  @override
  String get externalToolsScreenTitle => 'Remote MCP-Server';

  @override
  String get searchMcpCatalogTooltip => 'MCP-Server suchen';

  @override
  String get catalogUrlSaved => 'Katalog-URL gespeichert';

  @override
  String failedToSaveUrl(String error) {
    return 'Speichern der URL fehlgeschlagen: $error';
  }

  @override
  String testingServerMsg(String name) {
    return 'Teste $name…';
  }

  @override
  String mcpTestSuccessMsg(String detail) {
    return 'MCP-Server-Test erfolgreich. $detail';
  }

  @override
  String mcpTestFailedMsg(String error) {
    return 'MCP-Test fehlgeschlagen: $error';
  }

  @override
  String get serverUrlRequiredForTest =>
      'Server-URL ist für den Test erforderlich.';

  @override
  String get customServerAdded => 'Benutzerdefinierter MCP-Server hinzugefügt';

  @override
  String failedToAddCustomServer(String error) {
    return 'Fehler beim Hinzufügen des Servers: $error';
  }

  @override
  String get externalToolsGlobalInfo =>
      'Remote MCP-Server konfigurieren, die über HTTPS/SSE erreichbar sind. Beliebige Server mit MCP-Endpunkt hinzufügen — keine lokale Installation nötig.';

  @override
  String get catalogUrlLabel => 'Katalog-URL';

  @override
  String get saveUrlButton => 'URL speichern';

  @override
  String get smitheryApiKeyLabel => 'Smithery API-Schlüssel';

  @override
  String get smitheryApiKeyHint =>
      'Erhalte deinen auf smithery.ai/account/api-keys';

  @override
  String get smitheryApiKeyHelper =>
      'Wird automatisch für jeden server.smithery.ai-Endpunkt ohne eigenen Schlüssel verwendet.';

  @override
  String get smitheryApiKeySaved => 'Smithery API-Schlüssel gespeichert';

  @override
  String get saveSmitheryKeyButton => 'Smithery-Schlüssel speichern';

  @override
  String get addCustomMcpServerTitle =>
      'Benutzerdefinierten MCP-Server hinzufügen';

  @override
  String get mcpApiKeyBearerHint => 'Wird als Bearer-Token verwendet';

  @override
  String get mcpApiKeyOptionalLabel => 'API-Schlüssel (optional)';

  @override
  String get apiPasswordOptionalLabel => 'API-Passwort (optional)';

  @override
  String get mcpApiKeyBearerHelper =>
      'Für Smithery.ai-Server: Smithery API-Schlüssel verwenden (smithery.ai → Einstellungen → API-Schlüssel). Wird als Authorization: Bearer gesendet.';

  @override
  String get mcpApiPasswordOptionalHint => 'Optionaler Auth-Fallback';

  @override
  String get testButton => 'Testen';

  @override
  String get addButton => 'Hinzufügen';

  @override
  String get selectedMcpServersTitle => 'Ausgewählte MCP-Server';

  @override
  String selectedServersCount(int count) {
    return '$count ausgewählt';
  }

  @override
  String get noExternalToolsYet =>
      'Noch keine Remote MCP-Server konfiguriert. + tippen zum Hinzufügen.';

  @override
  String serverStatusTooltip(String status) {
    return 'Status: $status';
  }

  @override
  String get statusOnline => 'Online';

  @override
  String get statusOffline => 'Offline';

  @override
  String get statusUnknown => 'Unbekannt';

  @override
  String cloudMcpStatusLabel(String status) {
    return 'Cloud MCP · $status';
  }

  @override
  String get apiKeyConfiguredLabel => 'API-Schlüssel konfiguriert';

  @override
  String get apiKeyMissingLabel => 'API-Schlüssel fehlt';

  @override
  String get startPlayground => 'Playground starten';

  @override
  String get initialPromptHint =>
      'Optionale erste Nachricht – wird beim Start in das Eingabefeld vorausgefüllt.';

  @override
  String get scriptLibraryTooltip => 'Skriptbibliothek';

  @override
  String get scriptLibraryUpdated => 'Skriptbibliothek aktualisiert';

  @override
  String get toolboxChangesWarning =>
      'Änderungen setzen die aktuelle Sitzung zurück';

  @override
  String get toolSelectionBuiltIn => 'Integriert';

  @override
  String get toolSelectionExternal => 'Externe MCP-Server';

  @override
  String get chatSendHint => 'Nachricht senden, um zu beginnen…';

  @override
  String systemPromptTapToEdit(String label) {
    return '$label (tippen zum Bearbeiten)';
  }

  @override
  String get websiteUrlLabel => 'Website-URL';

  @override
  String get maxPagesLabel => 'Max. Seiten';

  @override
  String get websiteUrlInvalid => 'Eingegebene URL ist ungültig.';

  @override
  String get websiteUrlReady =>
      'Bereit zum Hinzufügen und Indexieren dieser URL.';

  @override
  String get websiteUrlAlreadyAdded =>
      'URL bereits ausgewählt oder max. Websites erreicht.';

  @override
  String websiteUrlLimitHint(int maxPages) {
    return 'Bis zu 3 Seiten. Indexierte Seiten werden in DuckDB gespeichert. Max. Seiten: $maxPages.';
  }

  @override
  String get addUrlButton => 'URL hinzufügen';

  @override
  String get noWebsitesSelected => 'Keine Websites ausgewählt';

  @override
  String websitesSelectedCount(int count) {
    return '$count Website(s) ausgewählt';
  }

  @override
  String get indexingActive => 'Indexierung…';

  @override
  String get deleteScriptTitle => 'Skript löschen?';

  @override
  String deleteScriptConfirm(String name) {
    return '$name\" löschen? Dies kann nicht rückgängig gemacht werden.';
  }

  @override
  String get shellScriptLibraryTitle => 'Shell-Skriptbibliothek';

  @override
  String get newScriptTooltip => 'Neues Skript';

  @override
  String get noScriptsYet => 'Noch keine Skripte.';

  @override
  String get createFirstScriptHint =>
      'Tippe +, um ein neues Shell-Skript zu erstellen.';

  @override
  String get createScriptButton => 'Skript erstellen';

  @override
  String scriptDeletedMsg(String name) {
    return '$name\" gelöscht';
  }

  @override
  String get editScriptTooltip => 'Bearbeiten';

  @override
  String get deleteScriptTooltip => 'Löschen';

  @override
  String get newShellScriptTitle => 'Neues Shell-Skript';

  @override
  String get editScriptDialogTitle => 'Skript bearbeiten';

  @override
  String get scriptNameLabel => 'Skriptname';

  @override
  String get scriptNameHint => 'z. B. disk_cleanup.sh';

  @override
  String get scriptDescriptionHint => 'Was macht dieses Skript?';

  @override
  String get generateWithAiLabel => 'Mit KI generieren';

  @override
  String get generateScriptHint => 'Beschreibe, was das Skript tun soll…';

  @override
  String get describeForGeneration => 'Beschreibe, was das Skript tun soll.';

  @override
  String get withCommentsLabel => 'Mit Kommentaren';

  @override
  String get generateButton => 'Generieren';

  @override
  String get noLlmForScript =>
      'Kein LLM konfiguriert. In Einstellungen einrichten oder zuerst eine Chat-Aufgabe öffnen.';

  @override
  String get scriptContentLabel => 'Skriptinhalt';

  @override
  String get insertIntoPromptButton => 'In Aufgaben-Prompt einfügen';

  @override
  String get insertedIntoPromptMsg => 'In Aufgaben-Prompt eingefügt.';

  @override
  String get scriptNameRequiredMsg => 'Skriptname ist erforderlich.';

  @override
  String scriptSaveFailed(String error) {
    return 'Speichern fehlgeschlagen: $error';
  }

  @override
  String scriptGenerationFailed(String error) {
    return 'Generierung fehlgeschlagen: $error';
  }

  @override
  String get sshScriptLibraryNote =>
      'Skripte für SSH können in der Skriptbibliothek hinzugefügt oder generiert werden.';

  @override
  String get openButtonLabel => 'Öffnen';

  @override
  String get externalMcpGlobalTitle => 'Externe MCP-Server (global)';

  @override
  String get externalMcpGlobalSubtitle =>
      'Umschalten, welche globalen Server für diese Aufgabe aktiv sind.';

  @override
  String get browseDriveTooltip => 'Drive durchsuchen';

  @override
  String get googleDriveLabel => 'Google Drive';

  @override
  String get noSubfoldersLabel => 'Keine Unterordner';

  @override
  String get addGoogleDriveFolder => 'Ordner hinzufügen';

  @override
  String get selectRootLabel => 'Stammordner wählen';

  @override
  String get selectHereLabel => 'Hier auswählen';

  @override
  String get generatePromptTopicHint => 'Thema (z.B. Dokumentensuche...)';

  @override
  String get generateLabel => 'Generieren';

  @override
  String get applyLabel => 'Übernehmen';

  @override
  String get systemPromptTitleLabel => 'System-Prompt';

  @override
  String get taskPromptTitleLabel => 'Aufgaben-Prompt';

  @override
  String get clear => 'Löschen';

  @override
  String get execInitializing => 'Initialisiere Aufgabe…';

  @override
  String get execSendingPrompt => 'Sende Prompt an KI…';

  @override
  String execAiError(String error) {
    return 'KI-Fehler: $error';
  }

  @override
  String get execNoResponse => 'Keine Antwort vom LLM erhalten.';

  @override
  String get execNoLlmResponse => 'Leere LLM-Antwort';

  @override
  String get execEmailSent => 'E-Mail gesendet';

  @override
  String execEmailSentWithMsg(String message) {
    return 'E-Mail gesendet: $message';
  }

  @override
  String execEmailError(String error) {
    return 'E-Mail Fehler: $error';
  }

  @override
  String get execCompleted => 'Ausführung abgeschlossen.';

  @override
  String execError(String error) {
    return 'Fehler: $error';
  }

  @override
  String get execNotReady => 'Task-Laufzeit nicht bereit. LLM konfiguriert?';

  @override
  String get execCheckChain => 'Prüfe Chain-Bedingung…';

  @override
  String get execChainDone => 'Chain-Aufgabe ausgeführt.';

  @override
  String execChainError(String error) {
    return 'Chain-Fehler: $error';
  }

  @override
  String get applyAndReset => 'Anwenden & Zurücksetzen';

  @override
  String get noToolsAvailable => 'Keine Tools verfügbar';

  @override
  String websiteIndexComplete(int count, int ms) {
    return 'Website-Index fertig: $count Seiten in ${ms}ms';
  }

  @override
  String get invalidWebsiteUrl => 'Ungültige Website-URL';

  @override
  String get maxWebsitesReached => 'Maximal 3 Websites erlaubt.';

  @override
  String get aboutTitle => 'Über TealKit';

  @override
  String get userGuide => 'Benutzerhandbuch';

  @override
  String get privacyPolicy => 'Datenschutzerklärung';

  @override
  String get psScriptLibraryTitle => 'PowerShell-Skriptbibliothek';

  @override
  String get psNewScriptTooltip => 'Neues PowerShell-Skript';

  @override
  String get psDeleteScriptTitle => 'PowerShell-Skript löschen';

  @override
  String psDeleteScriptConfirm(String name) {
    return '\"$name\" löschen?';
  }

  @override
  String psScriptDeleted(String name) {
    return 'Gelöscht: $name';
  }

  @override
  String get psNoScriptsYet => 'Noch keine PowerShell-Skripte';

  @override
  String get psCreateFirstScriptHint =>
      'Erstelle dein erstes PowerShell-Skript.';

  @override
  String get psCreateScriptButton => 'PowerShell-Skript erstellen';

  @override
  String get psNewScriptDialogTitle => 'Neues PowerShell-Skript';

  @override
  String get psEditScriptDialogTitle => 'PowerShell-Skript bearbeiten';

  @override
  String get psScriptNameRequired => 'Skriptname ist erforderlich.';

  @override
  String psSaveFailed(String error) {
    return 'Speichern fehlgeschlagen: $error';
  }

  @override
  String get psNoScriptContent => 'Kein Skriptinhalt zum Testen.';

  @override
  String get psWindowsOnlyTest =>
      'PowerShell-Test ist nur unter Windows verfügbar.';

  @override
  String get psTestRunTitle => 'Testlauf';

  @override
  String get psTestRunParams =>
      'Parameter (optionale Argumente für das Skript):';

  @override
  String get psTestRunFailed => 'Testlauf fehlgeschlagen';

  @override
  String psTestOutput(int code) {
    return 'Testausgabe (Exit-Code: $code)';
  }

  @override
  String get psRunsLocally => 'Läuft lokal auf diesem Windows-Rechner';

  @override
  String get psNoLlmConfigured => 'Kein LLM konfiguriert.';

  @override
  String psGenerationFailed(String error) {
    return 'Generierung fehlgeschlagen: $error';
  }

  @override
  String get psLoadSamplesTooltip => 'Beispielskripte laden';

  @override
  String psSamplesLoadedMsg(int count) {
    return '$count Beispielskripte hinzugefügt.';
  }

  @override
  String get vaultTitle => 'Einstellungs-Tresor';

  @override
  String get vaultSubtitle =>
      'Alle Einstellungen, Skripte und Aufgaben exportieren/importieren — verschlüsselt (.tkv)';

  @override
  String get vaultScreenTitle => 'Verschlüsseltes Einstellungs-Backup';

  @override
  String get vaultScreenDesc =>
      'Alle API-Schlüssel, Zugangsdaten und Integrationen in eine AES-256-verschlüsselte Datei speichern.';

  @override
  String get vaultIncludedLabel => 'Enthalten (pro Export wählbar)';

  @override
  String get vaultIncludedText =>
      'Konfiguration: LLM / API-Schlüssel / E-Mail / SSH / Integrationen\nSkripte: JS  •  PowerShell  •  Python  •  SSH-Skripte\nAufgaben: alle Aufgaben mit benutzerdefiniertem LLM, SSH & Zugangsdaten';

  @override
  String get vaultExcludedLabel => 'Nie enthalten';

  @override
  String get vaultExcludedText => 'Gesprächsverlauf  •  DuckDB-Dokumentindex';

  @override
  String get vaultExportSection => 'Tresor exportieren';

  @override
  String get vaultExportHint =>
      'Ordner wählen, dann Dateiname, Passwort und Abschnitte festlegen.';

  @override
  String get vaultChooseFolderExport => 'Ordner wählen & exportieren';

  @override
  String get vaultEncrypting => 'Verschlüsseln...';

  @override
  String vaultSaved(String name) {
    return 'Tresor gespeichert: $name';
  }

  @override
  String vaultExportFailed(String error) {
    return 'Export fehlgeschlagen: $error';
  }

  @override
  String get vaultImportSection => 'Tresor importieren';

  @override
  String get vaultImportHint =>
      'Eine .tkv-Datei auswählen, um Zugangsdaten und Einstellungen wiederherzustellen.';

  @override
  String get vaultPickFileImport => 'Datei wählen & wiederherstellen';

  @override
  String get vaultDecrypting => 'Entschlüsseln...';

  @override
  String vaultRestored(String name) {
    return 'Tresor wiederhergestellt aus $name';
  }

  @override
  String vaultImportFailed(String error) {
    return 'Import fehlgeschlagen: $error';
  }

  @override
  String get vaultDialogExportTitle => 'Tresor exportieren';

  @override
  String get vaultDialogImportTitle => 'Tresor importieren';

  @override
  String get vaultDialogPassword => 'Passwort';

  @override
  String get vaultDialogPasswordMin => 'Mind. 8 Zeichen';

  @override
  String get vaultDialogPasswordHint => 'Tresor-Passwort';

  @override
  String get vaultDialogPasswordLabel => 'Passwort (mind. 8 Zeichen)';

  @override
  String get vaultDialogConfirmPassword => 'Passwort bestätigen';

  @override
  String get vaultDialogEnterVaultPassword => 'Tresor-Passwort eingeben';

  @override
  String get vaultDialogPasswordShort => 'Mindestens 8 Zeichen';

  @override
  String get vaultPasswordMismatch => 'Passwörter stimmen nicht überein';

  @override
  String get vaultDialogFilenameLabel => 'Dateiname (.tkv)';

  @override
  String get vaultDialogEnterFilename => 'Dateiname eingeben';

  @override
  String get vaultDialogIncludeLabel => 'In Tresor einschließen:';

  @override
  String get vaultDialogSelectRestore =>
      'Wiederherzustellende Bereiche wählen:';

  @override
  String vaultDialogFrom(String name) {
    return 'Von: $name';
  }

  @override
  String get vaultSectionConfiguration => 'Konfiguration';

  @override
  String get vaultSectionConfigurationDesc =>
      'LLM, API-Schlüssel, E-Mail, SSH, Integrationen, alle Einstellungen';

  @override
  String get vaultSectionScripts => 'Skripte';

  @override
  String get vaultSectionScriptsDesc => 'JS, PowerShell, Python, SSH-Skripte';

  @override
  String get vaultSectionScriptsMobileDesc =>
      'JS & SSH-Skripte (PowerShell/Python auf mobilen Geräten übersprungen)';

  @override
  String get vaultSectionTasks => 'Aufgaben';

  @override
  String get vaultSectionTasksDesc =>
      'Alle Aufgaben mit benutzerdefiniertem LLM, SSH & API-Schlüsseln';

  @override
  String get vaultSectionSessions => 'Playground-Konfigurationen';

  @override
  String get vaultSectionSessionsDesc =>
      'Gespeicherte Playground-Konfigurationen (Tools & Prompts)';

  @override
  String get vaultSectionSkills => 'Tool-Skills';

  @override
  String get vaultSectionSkillsDesc =>
      'KI-generierte Anleitungen für MCP-Tools';

  @override
  String get vaultGreyedNotice =>
      'Ausgegraute Bereiche sind in dieser Tresor-Datei nicht vorhanden.';

  @override
  String get vaultExportButton => 'Exportieren';

  @override
  String get vaultRestoreButton => 'Wiederherstellen';

  @override
  String get skillsScreenTitle => 'Tool-Skills';

  @override
  String skillsScreenSubtitle(int count) {
    return '$count Skills – aktivierte Skills werden in System-Prompts für Tasks eingefügt, die diese Tools verwenden.';
  }

  @override
  String get skillsEmptyHint =>
      'Noch keine Skills vorhanden.\nStarte einen Chat, um die automatische Generierung auszulösen.';

  @override
  String get skillsFilterHint => 'Nach Tool oder Server filtern…';

  @override
  String get skillsCustomBadge => 'Benutzerdefiniert (manuell bearbeitet)';

  @override
  String get skillsMenuRegenerate => 'Nicht-benutzerdefinierte neu generieren';

  @override
  String get skillsMenuRegenerateDesc =>
      'Auto-Skills neu generieren, benutzerdefinierte behalten';

  @override
  String get skillsMenuRebuild => 'Neu aufbauen (alle Tools scannen)';

  @override
  String get skillsMenuRebuildDesc =>
      'Alle überschreiben  •  oder  •  nur fehlende hinzufügen';

  @override
  String get skillsRebuildDialogTitle => 'Skills neu aufbauen';

  @override
  String get skillsRebuildDialogDesc =>
      'Wähle, wie Skills für alle registrierten MCP-Tools neu aufgebaut werden sollen.';

  @override
  String get skillsRebuildOverwriteTitle => 'Alle Skills überschreiben';

  @override
  String get skillsRebuildOverwriteDesc =>
      'Alle Skills (inkl. benutzerdefinierte) löschen und von Grund auf neu generieren.';

  @override
  String get skillsRebuildAddMissingTitle => 'Nur fehlende Skills hinzufügen';

  @override
  String get skillsRebuildAddMissingDesc =>
      'Vorhandene Skills behalten. Nur für Tools ohne Skill generieren.';

  @override
  String skillsEditDialogTitle(String toolName) {
    return 'Skill bearbeiten: $toolName';
  }

  @override
  String get skillsFullSkillLabel => 'Vollständiger Skill (große Modelle)';

  @override
  String get skillsSlmSkillLabel => 'SLM-Skill (kleine / eingebettete Modelle)';

  @override
  String get docFileTypesLabel => 'Zu indizierende Dateitypen';

  @override
  String get docFileTypesReset => 'Zurücksetzen';

  @override
  String get docFileTypesAll => 'Alle';

  @override
  String get loadModelIntoApp => 'In App laden';

  @override
  String get unloadModel => 'Entladen';

  @override
  String get modelLoadedInApp => 'Im Speicher';

  @override
  String get loadingModelIntoApp => 'Wird geladen…';

  @override
  String loadingModelProgress(int percent) {
    return 'Modell laden… $percent%';
  }

  @override
  String get loadModelFailed => 'Modell konnte nicht geladen werden';

  @override
  String get execLoadingEmbeddedModel => 'Eingebettetes Modell wird geladen…';

  @override
  String get mcpRegistryInstallManuallyTooltip => 'Manuell installieren';

  @override
  String get mcpManualInstallDialogTitle => 'MCP-Server manuell installieren';

  @override
  String get mcpManualInstallDialogSubtitle =>
      'Installiere einen MCP-Server, der in keiner Registry aufgeführt ist.';

  @override
  String get mcpManualInstallNameLabel => 'Name';

  @override
  String get mcpManualInstallNameHint => 'z.B. Puppeteer MCP';

  @override
  String get mcpManualInstallUrlLabel => 'URL (optional)';

  @override
  String get mcpManualInstallUrlHint => 'https://github.com/…';

  @override
  String get mcpManualInstallTypeLabel => 'Typ';

  @override
  String get mcpManualInstallMethodLabel => 'Methode';

  @override
  String get mcpManualInstallTypeNodejs => 'Node.js';

  @override
  String get mcpManualInstallTypePython => 'Python';

  @override
  String get mcpManualInstallMethodNpm => 'npm install -g';

  @override
  String get mcpManualInstallMethodNpx => 'npx (bei Bedarf)';

  @override
  String get mcpManualInstallMethodUvx => 'uvx (empfohlen)';

  @override
  String get mcpManualInstallMethodPip => 'pip install';

  @override
  String get mcpManualInstallPackageLabel => 'Paket- / Servername';

  @override
  String get mcpManualInstallPackageHint => 'z.B. puppeteer-mcp-server';

  @override
  String get mcpManualInstallCommandLabel => 'Installationsbefehl(e)';

  @override
  String get mcpManualInstallCommandHint =>
      'Ein Befehl pro Zeile. Zeilen mit # sind Kommentare.';

  @override
  String get mcpManualInstallRegenerateTooltip => 'Befehl neu generieren';

  @override
  String get mcpManualInstallExecuteSaveButton => 'Ausführen & Speichern';

  @override
  String get mcpManualInstallRunningButton => 'Läuft…';

  @override
  String get mcpManualInstallDoneButton => 'Fertig';

  @override
  String get mcpManualInstallNoCommandsMsg =>
      'Keine Installationsbefehle (On-Demand-Launcher). Server wird registriert…';

  @override
  String get mcpManualInstallSuccessMsg =>
      '✓ Installation erfolgreich. Server wird gespeichert…';

  @override
  String get mcpManualInstallSaveFailedPrefix => 'Speichern fehlgeschlagen: ';

  @override
  String get mcpManualInstallCloseButton => 'Schließen';

  @override
  String get tooltipCopyMessage => 'Nachricht kopieren';

  @override
  String get tooltipDownloadFile => 'Datei herunterladen';

  @override
  String get tooltipCopyResult => 'Ergebnis kopieren';

  @override
  String get tooltipViewAllEmails => 'Alle E-Mails anzeigen';

  @override
  String get tooltipViewAllFiles => 'Alle Dateien anzeigen';

  @override
  String get tooltipViewFullScreen => 'Vollbildansicht';

  @override
  String get tooltipExportToPdf => 'Als PDF exportieren';

  @override
  String get tooltipDownloadImage => 'Bild herunterladen';

  @override
  String get tooltipShareFile => 'Datei teilen';

  @override
  String get tooltipCopyFolderPath => 'Ordnerpfad kopieren';

  @override
  String get tooltipFileDetails => 'Dateidetails';

  @override
  String get tooltipCopyAll => 'Alle kopieren';

  @override
  String get tooltipReadResource => 'Ressource lesen';

  @override
  String get tooltipCopySchema => 'Schema kopieren';

  @override
  String get tooltipRefresh => 'Aktualisieren';

  @override
  String get tooltipNewFolder => 'Neuer Ordner';

  @override
  String get tooltipUploadFile => 'Datei hochladen';

  @override
  String get tooltipUploadEnterPath => 'Hochladen (Quellpfad eingeben)';

  @override
  String get tooltipNoChanges => 'Keine Änderungen';

  @override
  String get tooltipUploadToServer => 'Auf Server hochladen';

  @override
  String get tooltipRename => 'Umbenennen';

  @override
  String get tooltipDeleteFile => 'Datei löschen';

  @override
  String get tooltipStopProcessing => 'Verarbeitung stoppen';

  @override
  String get tooltipExportToolList =>
      'Werkzeugliste für Modelltraining exportieren';

  @override
  String get tooltipDiscoverTools => 'Werkzeuge entdecken';

  @override
  String get labelImageNotAvailable => 'Bild nicht verfügbar';

  @override
  String get labelExcelFile => 'Excel-Datei';

  @override
  String get labelWordDocument => 'Word-Dokument';

  @override
  String get labelNoContent => 'Kein Inhalt';

  @override
  String get labelNoResultYet => 'Noch kein Ergebnis';

  @override
  String get labelNoMatchingEmails => 'Keine passenden E-Mails.';

  @override
  String get labelFilterEmails => 'E-Mails filtern…';

  @override
  String get labelFileNotFound => 'Datei an diesem Pfad nicht gefunden';

  @override
  String get labelToolNoResultData =>
      'Werkzeug ausgeführt, aber keine Ergebnisdaten verfügbar';

  @override
  String get labelToolCalledNoData =>
      'Werkzeug aufgerufen, aber keine Ergebnisdaten verfügbar';

  @override
  String get labelEmptyToolResult => '[Leeres Werkzeug-Ergebnis]';

  @override
  String get labelEmailBodyEmpty => 'E-Mail-Text ist leer.';

  @override
  String get labelFailedParseEmail => 'Fehler beim Parsen der E-Mail-Antwort.';

  @override
  String labelShowingEmailsOf(int count, int total) {
    return '$count von $total E-Mails';
  }

  @override
  String labelEmailsCount(int count) {
    return 'E-Mails ($count)';
  }

  @override
  String get dialogNewFolder => 'Neuer Ordner';

  @override
  String get dialogDeleteEmptyFolder => 'Leeren Ordner löschen';

  @override
  String get dialogDeleteFile => 'Datei löschen';

  @override
  String get dialogRenameFile => 'Datei umbenennen';

  @override
  String get dialogUploadFile => 'Datei hochladen';

  @override
  String get dialogEditView => 'Bearbeiten / Anzeigen';

  @override
  String get dialogDeleteConfirmPermanent => 'Endgültig löschen ';

  @override
  String get dialogSaveFile => 'Datei speichern';

  @override
  String get dialogSaveToolList => 'Werkzeugliste speichern';

  @override
  String msgFileSaved(String path) {
    return 'Datei gespeichert: $path';
  }

  @override
  String msgFailedDownload(String error) {
    return 'Herunterladen fehlgeschlagen: $error';
  }

  @override
  String msgSavedToDownloads(String fileName) {
    return 'Datei in Downloads gespeichert: $fileName';
  }

  @override
  String get msgFailedSaveFile => 'Datei konnte nicht gespeichert werden';

  @override
  String msgSavedToPath(String path) {
    return 'Gespeichert unter $path';
  }

  @override
  String get msgCopiedToClipboard => 'In Zwischenablage kopiert';

  @override
  String get msgToolResultCopied =>
      'Werkzeug-Ergebnis in Zwischenablage kopiert';

  @override
  String get msgToolCallCopied => 'Werkzeugaufruf in Zwischenablage kopiert';

  @override
  String get msgPathCopied => 'Pfad kopiert';

  @override
  String get msgConversationReset => 'Unterhaltung erfolgreich zurückgesetzt';

  @override
  String msgImageSavedDownloads(String fileName) {
    return 'Bild in Downloads gespeichert: $fileName';
  }

  @override
  String get msgFailedSaveImage => 'Bild konnte nicht gespeichert werden';

  @override
  String get msgExportCancelled => 'Export abgebrochen';

  @override
  String msgExportFailed(String error) {
    return 'Export fehlgeschlagen: $error';
  }

  @override
  String get msgSplitPromptInfo =>
      'In Unter-Prompts aufteilen — getrennt durch ++#++';

  @override
  String msgFailedAttachFile(String error) {
    return 'Datei anhängen fehlgeschlagen: $error';
  }

  @override
  String msgFailedAttachImage(String error) {
    return 'Bild anhängen fehlgeschlagen: $error';
  }

  @override
  String msgOfficeDocNotSupported(String name) {
    return 'Office-Dokumente ($name) werden vom KI-Assistenten nicht unterstützt.\n\nUnterstützte Formate:\n• Bilder (PNG, JPG, GIF, WebP)\n• PDF-Dateien\n• Textdateien\n\nBitte konvertieren Sie Ihr Office-Dokument in PDF oder kopieren Sie den Textinhalt.';
  }

  @override
  String get msgEnterFilename => 'Bitte geben Sie einen Dateinamen ein';

  @override
  String msgFailedGeneratePdf(String error) {
    return 'PDF-Generierung fehlgeschlagen: $error';
  }

  @override
  String get msgNetworkImageExportNotSupported =>
      'Export von Netzwerkbildern wird noch nicht unterstützt';

  @override
  String get labelFolderName => 'Ordnername';

  @override
  String get labelSourcePath => 'Quellpfad';

  @override
  String get labelNewName => 'Neuer Name';

  @override
  String get labelRemoteTarget => 'Remote-Ziel';

  @override
  String get labelSearchFiles => 'Dateien durchsuchen...';

  @override
  String get labelNoFilesFound => 'Keine Dateien gefunden';

  @override
  String get labelFileName => 'Dateiname';

  @override
  String get labelEnterFilename => 'Dateinamen eingeben';

  @override
  String get hintTypeMessage => 'Nachricht eingeben...';

  @override
  String get hintAddCaption => 'Bildunterschrift hinzufügen...';

  @override
  String get hintEnterSourcePath => '/home/user/datei.txt';

  @override
  String get statusNoActiveTask => 'Keine aktive Aufgabe';

  @override
  String get statusSelectTaskToSeeTools =>
      'Wähle eine Aufgabe, um\nverfügbare Werkzeuge zu sehen';

  @override
  String get statusNoToolsAvailable => 'Keine Werkzeuge verfügbar';

  @override
  String get statusNoResourcesAvailable => 'Keine Ressourcen verfügbar';

  @override
  String get statusLoadingTools => 'Werkzeuge werden geladen...';

  @override
  String get statusConnectToSeeTools =>
      'Verbinde mit MCP-Servern,\num Werkzeuge zu sehen';

  @override
  String statusNoToolsForServer(String server) {
    return 'Keine Werkzeuge verfügbar für $server';
  }

  @override
  String get placeholderAllServers => 'Alle Server';

  @override
  String get labelIncludeServerTag => 'Server-Tag einfügen';

  @override
  String get labelAllSelected => 'Alle ausgewählt';

  @override
  String get labelSelectAll => 'Alle auswählen';

  @override
  String get splitPromptInstruction =>
      'Teile die Benutzeranfrage in aufeinanderfolgende Unter-Prompts auf. Verbinde sie mit dem Trennzeichen ++#++ in einer eigenen Zeile zwischen den Schritten. Jeder Unter-Prompt ist eine vollständige eigenständige Anweisung. Gib NUR die Unter-Prompts mit dem Trennzeichen dazwischen aus. Kein zusätzlicher Text.';

  @override
  String splitPromptHint(Object tool_result) {
    return 'Prompt in Unter-Prompts aufteilen\n\nZum Teilen tippen:\n• Zeilen mit \\n → sofort teilen\n• ✦ für KI-Teilung\n\nTrennzeichen: ++#++ (eigene Zeile)\nVorherige Werkzeugausgabe einfügen: \$$tool_result';
  }

  @override
  String labelSplitFailed(String error) {
    return 'Teilung fehlgeschlagen: $error';
  }

  @override
  String get renameAgentTitle => 'Agent umbenennen';

  @override
  String get agentNameLabel => 'Name';

  @override
  String get renameLabel => 'Umbenennen';

  @override
  String get nextStepRoutingTitle => 'Routing zum nächsten Schritt';

  @override
  String get routingModeSequential => 'Sequenziell (Nächster Agent)';

  @override
  String get routingModeConditional => 'Konditional (Verzweigung)';

  @override
  String get routingModeScheduled => 'Geplant (Unabhängig)';

  @override
  String get agentScheduleTitle => 'Agent Zeitplan';

  @override
  String get schedulingDisabledWarning =>
      'Die Zeitplanung ist deaktiviert, da dieser Agent sequenziell oder konditional von einem vorherigen aufgerufen wird.';

  @override
  String get tagsLabel => 'Tags (kommagetrennt)';

  @override
  String get removeAgentTooltip => 'Agent entfernen';

  @override
  String get addAgentTooltip => 'Agent hinzufügen';

  @override
  String get routingModeLabel => 'Routing-Modus';

  @override
  String conditionRuleHeader(int index) {
    return 'Bedingungsregel #$index';
  }

  @override
  String get removeConditionRuleTooltip => 'Bedingungsregel entfernen';

  @override
  String get targetAgentLabel => 'Ziel-Agent';

  @override
  String get addRoutingRuleLabel => 'Routing-Regel hinzufügen';

  @override
  String get addAgentFirstWarning =>
      'Füge zuerst einen weiteren Agenten hinzu, um konditionales Routing zu konfigurieren.';

  @override
  String get operatorLabel => 'Operator';

  @override
  String get customExpressionLabel => 'Benutzerdefinierter Ausdruck';

  @override
  String get customExpressionHint => 'z.B. avg value > 5';

  @override
  String get valueLabel => 'Wert';

  @override
  String get valueHint => 'Wert zum Vergleichen';

  @override
  String get agentScheduleHeader => 'Agent Zeitplan';

  @override
  String get operatorLess => 'Kleiner (<)';

  @override
  String get operatorLessOrEquals => 'Kleiner oder gleich (<=)';

  @override
  String get operatorEquals => 'Gleich (==)';

  @override
  String get operatorNotEqual => 'Ungleich (!=)';

  @override
  String get operatorGreaterThan => 'Größer (>)';

  @override
  String get operatorGreaterOrEquals => 'Größer oder gleich (>=)';

  @override
  String get operatorContains => 'Enthält';

  @override
  String get operatorNotContains => 'Enthält nicht';

  @override
  String get operatorCustom => 'Benutzerdefinierter Ausdruck';

  @override
  String get operatorLlmEval => 'Durch LLM auswerten';

  @override
  String get llmConditionLabel => 'Bedingung auswerten';

  @override
  String get llmConditionHint => 'z.B. Batteriespannung > 5';

  @override
  String get cancelExecution => 'Ausführung abbrechen';

  @override
  String get inactive => 'Inaktiv';

  @override
  String get noAgentLogs =>
      'Keine Ausführungsprotokolle für diesen Workflow aufgezeichnet.';

  @override
  String agentLogsTitle(String name) {
    return 'Ausführungsprotokolle: $name';
  }

  @override
  String skillLlmNotConfigured(String provider, String model) {
    return 'Das in diesem Skill konfigurierte LLM ($provider / $model) ist nicht verfügbar. Stattdessen wird das Standard-LLM verwendet.';
  }

  @override
  String get llmWarning => 'LLM-Warnung';
}
