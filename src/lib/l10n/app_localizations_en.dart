// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class LEn extends L {
  LEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'TealKit';

  @override
  String get appSubtitle => 'Your personal AI assistant';

  @override
  String get getStarted => 'Get Started';

  @override
  String get viewLogs => 'View Logs';

  @override
  String get playground => 'Playground';

  @override
  String get playgroundHint =>
      'Try out prompts, tools and system instructions here before scheduling a workflow.';

  @override
  String get tasks => 'Workflows';

  @override
  String get firstStep => 'First Step';

  @override
  String get settings => 'Settings';

  @override
  String get configureLlmFirst =>
      'Configure an LLM provider to unlock Playground and Workflows.';

  @override
  String get systemPrompt => 'System Prompt';

  @override
  String get initialPrompt => 'Initial Prompt';

  @override
  String get generatePrompt => 'Generate';

  @override
  String get generateSystemPromptHint =>
      'Enter a subject above, then tap ✦ to generate an AI-suggested system prompt.';

  @override
  String get promptSubject => 'Subject (e.g. document search)';

  @override
  String get selectTools => 'Select Tools';

  @override
  String toolsSelected(int count) {
    return '$count tools selected';
  }

  @override
  String get resetChat => 'Reset Chat';

  @override
  String get gmailSearch => 'Gmail (Search)';

  @override
  String get imapSend => 'SMTP (Send)';

  @override
  String get testVia => 'Test via';

  @override
  String get emailSearchGmail => 'Use Gmail API for searching emails';

  @override
  String get emailSendImap => 'Use SMTP for sending emails';

  @override
  String get taskScheduler => 'Workflow Scheduler';

  @override
  String get newTask => 'New Workflow';

  @override
  String get editTask => 'Edit Workflow';

  @override
  String get createTask => 'Create Workflow';

  @override
  String get saveAsTask => 'Save as Workflow';

  @override
  String get deleteTask => 'Delete Workflow';

  @override
  String deleteTaskConfirm(String name) {
    return 'Are you sure you want to delete \"$name\"?';
  }

  @override
  String get taskCreated => 'Workflow created';

  @override
  String get taskUpdated => 'Workflow updated';

  @override
  String taskDeleted(String name) {
    return 'Workflow \"$name\" deleted';
  }

  @override
  String failedToSave(String error) {
    return 'Failed to save: $error';
  }

  @override
  String failedToLoad(String error) {
    return 'Failed to load workflows: $error';
  }

  @override
  String get save => 'Save';

  @override
  String get cancel => 'Cancel';

  @override
  String get ok => 'OK';

  @override
  String get filterScheduledOnly => 'Scheduled only';

  @override
  String get filterAllTasks => 'All workflows';

  @override
  String get close => 'Close';

  @override
  String get delete => 'Delete';

  @override
  String get edit => 'Edit';

  @override
  String get copy => 'Copy';

  @override
  String get remove => 'Remove';

  @override
  String get reload => 'Reload';

  @override
  String get enable => 'Enable';

  @override
  String get disable => 'Disable';

  @override
  String get enabled => 'Enabled';

  @override
  String get disabled => 'Disabled';

  @override
  String get yes => 'Yes';

  @override
  String get no => 'No';

  @override
  String get tabBasic => 'Basic';

  @override
  String get tabPrompts => 'Prompts';

  @override
  String get tabSchedule => 'Schedule';

  @override
  String get tabLlm => 'LLM';

  @override
  String get tabMcp => 'MCP';

  @override
  String get tabBuiltIn => 'Tools';

  @override
  String get tabData => 'Data Sources';

  @override
  String get tabNotify => 'Output';

  @override
  String get sectionGeneral => 'General';

  @override
  String get sectionPrompts => 'Prompts';

  @override
  String get sectionSchedule => 'Schedule';

  @override
  String get sectionExecution => 'Execution';

  @override
  String get taskName => 'Workflow Name *';

  @override
  String get taskNameHint => 'e.g. Daily News Summary';

  @override
  String get nameRequired => 'Name is required';

  @override
  String get description => 'Description';

  @override
  String get descriptionHint => 'What does this task do?';

  @override
  String get agentId => 'Agent ID';

  @override
  String get agentIdHint => 'Optional: link to a specific agent';

  @override
  String get tags => 'Tags';

  @override
  String get tagsHint => 'comma separated: news, daily, summary';

  @override
  String get taskEnabledSubtitle =>
      'Workflow will run on schedule when enabled';

  @override
  String get systemPromptHint => 'You are a helpful assistant...';

  @override
  String get taskPrompt => 'Workflow Prompt *';

  @override
  String get taskPromptHint => 'Summarize top AI news from the last 24h...';

  @override
  String get promptRequired => 'Prompt is required';

  @override
  String get cronSchedule => 'Cron Schedule';

  @override
  String get cronExpression => 'Cron Expression *';

  @override
  String get cronFormat => 'Format: minute hour day month weekday';

  @override
  String get cronRequired => 'Cron expression required';

  @override
  String get scheduleDescription => 'Schedule Description';

  @override
  String get scheduleDescriptionHint => 'e.g. Every day at 8:00';

  @override
  String get cronEveryMinute => 'Every minute';

  @override
  String get cronHourly => 'Hourly';

  @override
  String get cronDaily8am => 'Daily 8am';

  @override
  String get cronDaily6pm => 'Daily 6pm';

  @override
  String get cronMonFri9am => 'Mon-Fri 9am';

  @override
  String get cronWeeklyMon => 'Weekly (Mon)';

  @override
  String get cronMonthly1st => 'Monthly 1st';

  @override
  String get schedulePickerTitle => 'Schedule';

  @override
  String get scheduleMinutes => 'Minutes';

  @override
  String get scheduleHourly => 'Hourly';

  @override
  String get scheduleDaily => 'Daily';

  @override
  String get scheduleWeekly => 'Weekly';

  @override
  String get scheduleMonthly => 'Monthly';

  @override
  String get scheduleCustom => 'Custom';

  @override
  String scheduleEveryNMinutes(int n) {
    return 'Every $n minutes';
  }

  @override
  String scheduleEveryNHours(int n) {
    return 'Every $n hours';
  }

  @override
  String get scheduleAtHour => 'At hour';

  @override
  String get scheduleAtMinute => 'At minute';

  @override
  String get scheduleOnDays => 'On days';

  @override
  String get scheduleOnDayOfMonth => 'On day of month';

  @override
  String get scheduleMon => 'Mon';

  @override
  String get scheduleTue => 'Tue';

  @override
  String get scheduleWed => 'Wed';

  @override
  String get scheduleThu => 'Thu';

  @override
  String get scheduleFri => 'Fri';

  @override
  String get scheduleSat => 'Sat';

  @override
  String get scheduleSun => 'Sun';

  @override
  String get errorHandling => 'Error Handling';

  @override
  String get maxRetries => 'Max Retries';

  @override
  String get retryDelay => 'Retry Delay (min)';

  @override
  String get timeout => 'Timeout (sec)';

  @override
  String get retryOnFailure => 'Retry on Failure';

  @override
  String get executeImmediately => 'Execute Immediately';

  @override
  String get llmOverride => 'LLM Override';

  @override
  String get overrideDefaultLlm => 'Override default LLM config';

  @override
  String get overrideDefaultLlmSubtitle =>
      'Use a specific model/provider for this task';

  @override
  String get provider => 'Provider';

  @override
  String get model => 'Model';

  @override
  String get modelHint => 'e.g. gpt-4o, gemini-2.5-flash';

  @override
  String get apiKey => 'API Key';

  @override
  String get apiKeyHint => 'sk-...';

  @override
  String get apiKeyNotSet => 'Not set';

  @override
  String get baseUrl => 'Base URL';

  @override
  String get baseUrlHint => 'http://localhost:11434 (for Ollama)';

  @override
  String get temperature => 'Temperature';

  @override
  String get maxTokens => 'Max Tokens';

  @override
  String get mcpServers => 'MCP Servers';

  @override
  String get addServer => 'Add Server';

  @override
  String get editMcpServer => 'Edit MCP Server';

  @override
  String get addMcpServer => 'Add MCP Server';

  @override
  String get noMcpServers => 'No MCP servers configured';

  @override
  String get noMcpServersSubtitle =>
      'Add a server to give this task access to external tools';

  @override
  String get discoverTools => 'Discover tools';

  @override
  String get specUrl => 'Spec URL';

  @override
  String get apiPassword => 'API Password';

  @override
  String get serverUrl => 'Server URL *';

  @override
  String get serverUrlHint => 'https://example.com/myserver';

  @override
  String get urlRequired => 'URL is required';

  @override
  String get mcpEndpoint => 'MCP Endpoint';

  @override
  String get mcpEndpointHint => '/mcp';

  @override
  String get mcpEndpointHelper => 'JSON-RPC endpoint path (default: /mcp)';

  @override
  String get specificationUrl => 'Specification URL';

  @override
  String get specificationUrlHint => 'Optional: OpenAPI/MCP spec endpoint';

  @override
  String get serverName => 'Name';

  @override
  String get serverNameHint => 'My MCP Server';

  @override
  String get optional => 'Optional';

  @override
  String get enabledTools => 'Enabled tools:';

  @override
  String get discovered => 'Discovered:';

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
    return 'Resources ($count)';
  }

  @override
  String toolsChip(int count) {
    return '$count tools';
  }

  @override
  String get builtInMcpServers => 'Built-in MCP Servers';

  @override
  String get builtInMcpSubtitle =>
      'Internal tools that run locally in the app — no external server needed.';

  @override
  String get addToTask => 'Add to task';

  @override
  String get tapToEnable => 'Tap to enable this built-in MCP';

  @override
  String typeLabel(String type) {
    return 'Type: $type';
  }

  @override
  String get configuration => 'Configuration';

  @override
  String get mcpSystemPrompt => 'System Prompt';

  @override
  String get mcpSystemPromptHelper =>
      'Instructs the LLM how to use this MCP\'s tools effectively.';

  @override
  String get mcpSystemPromptHint => 'Enter system prompt…';

  @override
  String get resetToDefault => 'Reset to default';

  @override
  String get appendMainSystemPrompt => 'Append main system prompt';

  @override
  String get mainSystemPromptAppended => 'Main system prompt appended';

  @override
  String get noMainSystemPrompt => 'No main system prompt set for this task';

  @override
  String get availableTools => 'Available Tools';

  @override
  String get noBuiltInMcp => 'No built-in MCP servers available.';

  @override
  String get globalMcpServersNote =>
      'These servers are configured globally in External Tools settings and are always available to this task.';

  @override
  String get noGlobalMcpServers =>
      'No external MCP servers configured. Add them in External Tools settings.';

  @override
  String defaultPrefix(String value) {
    return 'Default: $value';
  }

  @override
  String get dataSources => 'Data Sources';

  @override
  String get dataSourcesSubtitle =>
      'Enable or disable data sources for this task. Credentials are configured globally in the Data Sources settings on the start screen.';

  @override
  String get dataSourcesGlobalSubtitle =>
      'Configure global credentials for data sources. These are stored securely on your device.';

  @override
  String get dataSourcesNotConfiguredHint =>
      'Not configured – set up in Data Sources on the start screen';

  @override
  String get dataSourcesConfiguredHint => 'Credentials configured globally';

  @override
  String get dataSourcesSettingsSaved => 'Data source settings saved';

  @override
  String dataSourcesSettingsSaveFailed(String error) {
    return 'Failed to save: $error';
  }

  @override
  String get dataSourcesSettingsCleared => 'All data source settings cleared';

  @override
  String get dataSourcesClearTitle => 'Clear all data source settings?';

  @override
  String get dataSourcesClearMessage =>
      'This will remove all stored credentials. Data sources will need to be reconfigured.';

  @override
  String dataSourcesConfigured(int count) {
    return '$count data source(s) configured';
  }

  @override
  String get dataSourcesNone => 'No data sources configured';

  @override
  String get emailProvider => 'Email Provider';

  @override
  String get emailProviderSubtitle =>
      'Read and search emails, send notifications';

  @override
  String get imapProvider => 'IMAP (generic)';

  @override
  String get imapHost => 'IMAP Host (inbound)';

  @override
  String get imapHostHint => 'imap.example.com';

  @override
  String get imapPort => 'Port';

  @override
  String get imapUsername => 'Username';

  @override
  String get imapPassword => 'Password';

  @override
  String get imapUseSsl => 'Use SSL/TLS';

  @override
  String get smtpHost => 'SMTP Host (outgoing)';

  @override
  String get smtpHostHint => 'smtp.example.com';

  @override
  String get smtpPort => 'SMTP Port';

  @override
  String get smtpSender => 'Sender Email';

  @override
  String get smtpSenderHint => 'your-email@example.com';

  @override
  String get notificationEmail => 'Use for task notifications';

  @override
  String get notificationEmailHint => 'Send task outputs via this email';

  @override
  String get googleServices => 'Google Services';

  @override
  String get googleServicesSubtitle => 'Gmail search and Google Drive access';

  @override
  String get imapSmtpEmail => 'Email Send (SMTP)';

  @override
  String get imapSmtpEmailSubtitle => 'Send emails via external mail server';

  @override
  String get cloudStorage => 'Cloud Storage';

  @override
  String get cloudStorageSubtitle =>
      'Access files from Google Drive or OneDrive';

  @override
  String get googleDrive => 'Google Drive';

  @override
  String get oneDrive => 'Microsoft OneDrive';

  @override
  String get oneDriveSubtitle => 'Access files from Microsoft OneDrive';

  @override
  String get oneDriveClientId => 'Application (Client) ID';

  @override
  String get oneDriveClientIdHint => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';

  @override
  String get oneDriveTenantId => 'Directory (Tenant) ID';

  @override
  String get oneDriveTenantIdHint => 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';

  @override
  String get gmail => 'Google Mail (Gmail)';

  @override
  String get gmailSubtitle => 'Read emails via Gmail API with OAuth2';

  @override
  String get gmailSetup =>
      'You need a Google Cloud project with Gmail API enabled and OAuth2 credentials (Desktop app type).';

  @override
  String get oauthClientId => 'OAuth2 Client ID *';

  @override
  String get oauthClientIdHint => '123456-abc.apps.googleusercontent.com';

  @override
  String get oauthClientSecret => 'OAuth2 Client Secret *';

  @override
  String get oauthClientSecretHint => 'GOCSPX-...';

  @override
  String get authorizeGoogle => 'Authorize with Google';

  @override
  String get oauthAuthorizationCode => 'Authorization Code';

  @override
  String get oauthAuthorizationCodeHint =>
      'Paste the code or the full callback URL (http://localhost/?code=...)';

  @override
  String get exchangeAuthorizationCode => 'Exchange Code';

  @override
  String get oauthOpenSuccess =>
      'Google consent opened. After login, copy from browser URL (code=...) or paste the full callback URL here.';

  @override
  String get oauthOpenFailed => 'Could not open Google consent screen.';

  @override
  String get oauthCodeRequired => 'Authorization code is required.';

  @override
  String get oauthExchangeSuccess => 'Google OAuth connected successfully.';

  @override
  String oauthExchangeFailed(String error) {
    return 'Google OAuth exchange failed: $error';
  }

  @override
  String oauthTokenStatusReady(String email, String expiry) {
    return 'OAuth connected for $email, token expires at $expiry';
  }

  @override
  String get oauthTokenStatusMissing => 'OAuth token not connected yet.';

  @override
  String get sendTestEmail => 'Send Test Email';

  @override
  String get testEmailRecipient => 'Test Recipient';

  @override
  String get testEmailRecipientRequired => 'Test recipient email is required.';

  @override
  String get testEmailSent => 'Test email sent successfully.';

  @override
  String testEmailFailed(String error) {
    return 'Test email failed: $error';
  }

  @override
  String get oauthNotYet =>
      'OAuth2 flow not yet implemented — save credentials first';

  @override
  String get na => 'N/A';

  @override
  String get webSearch => 'Web Search';

  @override
  String get webSearchSubtitle => 'Search the web via Google or DuckDuckGo';

  @override
  String get searchProvider => 'Search Provider';

  @override
  String get customProvider => 'Custom Provider';

  @override
  String get customProviderSetup => 'Custom provider setup';

  @override
  String get customProviderName => 'Provider name';

  @override
  String get customProviderNameHint => 'e.g. Internal Search API';

  @override
  String get customProviderEndpoint => 'Provider endpoint URL';

  @override
  String get customProviderEndpointHint => 'https://example.com/search';

  @override
  String get serperProvider => 'Serper.dev';

  @override
  String get serperSetup => 'Serper.dev setup';

  @override
  String get serperApiKeyHint => 'serper_... or your API key';

  @override
  String get serpApiProvider => 'SerpApi (Google Search)';

  @override
  String get serpApiSetup =>
      'SerpApi uses the Google Search API. Requires an API key from serpapi.com.';

  @override
  String get serpApiKeyHint => 'Your SerpApi API key';

  @override
  String get duckDuckGo => 'DuckDuckGo (no API key needed)';

  @override
  String get googleCustomSearch => 'Google Custom Search';

  @override
  String get googleSearchSetup =>
      'Requires a Google Cloud API Key and a Programmable Search Engine ID (CSE).';

  @override
  String get searchEngineId => 'Search Engine ID *';

  @override
  String get searchEngineIdHint => 'a1b2c3d4e5f...';

  @override
  String get maxResults => 'Max Results';

  @override
  String get testSearchQuery => 'Test Search Query';

  @override
  String get testSearchQueryHint => 'e.g. Flutter latest news';

  @override
  String get testSearch => 'Test Search';

  @override
  String testSearchSuccess(int count, String provider) {
    return 'Search successful — $count results from $provider.';
  }

  @override
  String testSearchFailed(String error) {
    return 'Search test failed: $error';
  }

  @override
  String get testDriveConnection => 'Test Connection';

  @override
  String testDriveSuccess(int count) {
    return 'Connected — $count items found in root folder.';
  }

  @override
  String testDriveFailed(String error) {
    return 'Drive test failed: $error';
  }

  @override
  String get serverLoadingSettingsTitle => 'Loading settings...';

  @override
  String get serverLoadingSettingsBody =>
      'Server settings are being loaded into the app. Please wait.';

  @override
  String get serverSwitchTitle => 'Switch To Server Mode';

  @override
  String get serverSwitchBody =>
      'You are switching to server mode. Agents, schedules, and settings will use the remote server database. The local database stays separate and is not synchronized.';

  @override
  String get serverSwitchAction => 'Switch';

  @override
  String get serverConnected => 'Connected to server!';

  @override
  String get serverConnectionFailed =>
      'Connection failed — check server URL and API key authorization.';

  @override
  String get serverNotReachable => 'Server not reachable.';

  @override
  String get serverReachableAuthorized =>
      'Server reachable and authorization is valid.';

  @override
  String get serverReachableUnauthorized =>
      'Server reachable, but API key authorization failed.';

  @override
  String get serverSettingsTitle => 'Server Mode Settings';

  @override
  String serverSettingsError(String error) {
    return 'Error: $error';
  }

  @override
  String get serverSettingsUrlLabel => 'Server URL';

  @override
  String get serverSettingsUrlHint => 'http://192.168.1.100:7771';

  @override
  String get serverSettingsUrlHelper => 'Include port; no trailing slash';

  @override
  String get serverSettingsUrlInvalid => 'Enter a valid URL';

  @override
  String get serverTestConnectionButton => 'Test Connection';

  @override
  String get serverConnecting => 'Connecting...';

  @override
  String get serverConnectUseRemote => 'Connect & Use Remote';

  @override
  String get serverAboutTitle => 'About Server Mode';

  @override
  String get serverAboutBody =>
      'Server Mode connects this app to a TealKit Server instance running on your home server, NAS, or Raspberry Pi.\n\nTask data will be read from and written to the remote server. Schedule execution also happens on the server — the app does not need to be open.';

  @override
  String get serverApiKeyTitle => 'Server API Key';

  @override
  String get serverApiKeyBody =>
      'This app has auto-generated a unique API key. Configure your TealKit Server with it so only this app can connect.';

  @override
  String get serverCopyFullKeyTooltip => 'Copy full key';

  @override
  String get serverApiKeyCopied => 'API key copied to clipboard';

  @override
  String get serverApiKeyEnvHint =>
      'Set this as an environment variable when starting the server:\ndocker run -e TEALKIT_API_KEY=<key> ...';

  @override
  String get emailNotification => 'Email Notification';

  @override
  String get sendEmailAfterTask => 'Send email after task runs';

  @override
  String get toEmail => 'To (email)';

  @override
  String get toEmailHint => 'user@example.com';

  @override
  String get subject => 'Subject';

  @override
  String get subjectHint => 'Task Result: [task_name]';

  @override
  String get sendCondition => 'Send Condition';

  @override
  String get always => 'Always';

  @override
  String get onSuccess => 'On Success';

  @override
  String get onFailure => 'On Failure';

  @override
  String get onResultChange => 'On Result Change';

  @override
  String get outputType => 'Output Type';

  @override
  String get outputTypeEmail => 'Email';

  @override
  String get outputTypeFile => 'File';

  @override
  String get outputTypeSftp => 'SFTP Upload';

  @override
  String get sftpUseConfiguredSshServer => 'Use configured SSH server';

  @override
  String get sftpHost => 'SFTP Host';

  @override
  String get sftpPort => 'Port';

  @override
  String get sftpUsername => 'Username';

  @override
  String get sftpPassword => 'Password';

  @override
  String get sftpRemotePath => 'Default Folder (Remote Path)';

  @override
  String get sftpRemotePathHint => 'e.g. /uploads/tealkit';

  @override
  String get sftpNotifyByEmail => 'Send notification e-mail after upload';

  @override
  String get sftpNotifyEmailAddress => 'Notification e-mail address';

  @override
  String get sftpNotifyEmailSubject => 'Subject';

  @override
  String get sftpNotifyEmailBody => 'Body (leave blank for default template)';

  @override
  String get sftpNotifyEmailBodyHint => 'Leave blank for auto-generated text';

  @override
  String get outputDirectory => 'Output Directory';

  @override
  String get outputDirectoryHint =>
      'Choose where generated files should be saved';

  @override
  String get outputDirectoryNote =>
      'Directory picker availability depends on platform permissions.';

  @override
  String get outputFolderRequired =>
      'An output folder must be selected when using File output type. Tap the folder icon to choose a directory.';

  @override
  String get chooseDirectory => 'Choose Directory';

  @override
  String get fileNamePattern => 'File Name Pattern';

  @override
  String fileNamePatternHint(Object date) {
    return 'task_result_$date.txt';
  }

  @override
  String get addExecutionLogToOutput => 'Add execution log to output';

  @override
  String get zipOutputFiles => 'Zip output files';

  @override
  String get runningTaskWithDuckdb =>
      'Running task and indexing/searching with DuckDB...';

  @override
  String get openLatestFile => 'Open latest file';

  @override
  String get pathNotFound => 'Path not found';

  @override
  String openFailed(String error) {
    return 'Open failed: $error';
  }

  @override
  String get localSearchIndexDuckdb => 'Local search index (DuckDB)';

  @override
  String get duckdbSizeLimitDescription =>
      'Maximum indexed data size in GB. Indexing stops when the cap is reached.';

  @override
  String get duckdbSizeLimitGb => 'DuckDB size limit (GB)';

  @override
  String get duckdbSizeLimitHint => '1.0';

  @override
  String get pushNotification => 'Push Notification';

  @override
  String get sendPush => 'Send push notification';

  @override
  String get title => 'Title';

  @override
  String get titleHint => 'Task completed';

  @override
  String get deviceToken => 'Device Token';

  @override
  String get noTasksYet => 'No workflows yet';

  @override
  String get createScheduledTask =>
      'Create a scheduled workflow for your AI assistant';

  @override
  String get browseExamples => 'Browse Examples';

  @override
  String get browseExamplesTooltip => 'Pick a predefined example task';

  @override
  String get orStartFromExample => 'or start from an example';

  @override
  String get initialMessage => 'Initial Message';

  @override
  String get fieldRequired => 'This field is required';

  @override
  String get invalidEmail => 'Enter a valid email address';

  @override
  String get searchTasks => 'Search workflows...';

  @override
  String get noMatchingTasks => 'No matching workflows found';

  @override
  String lastRun(String date) {
    return 'Last: $date';
  }

  @override
  String nextRun(String date) {
    return 'Next: $date';
  }

  @override
  String get never => 'Never';

  @override
  String get columnActions => 'Actions';

  @override
  String get columnName => 'Name';

  @override
  String get columnUpdated => 'Updated';

  @override
  String get columnPrompt => 'Prompt';

  @override
  String get columnSchedule => 'Schedule';

  @override
  String get columnStatus => 'Status';

  @override
  String get columnEnabled => 'Enabled';

  @override
  String get columnLastRun => 'Last Run';

  @override
  String get costLastShort => 'Last';

  @override
  String get costTotalShort => 'Total';

  @override
  String get executeNow => 'Execute now';

  @override
  String get taskRunSuccess => 'Workflow executed successfully';

  @override
  String get taskRunFailed => 'Workflow execution finished with errors';

  @override
  String taskRunError(String error) {
    return 'Workflow execution failed: $error';
  }

  @override
  String get statusDisabled => 'Disabled';

  @override
  String get statusFailed => 'Failed';

  @override
  String statusFailedCount(int count) {
    return 'Failed ($count in a row)';
  }

  @override
  String statusOk(int count) {
    return 'OK — $count runs';
  }

  @override
  String get statusPending => 'Pending';

  @override
  String get statusPendingNeverRun => 'Pending — never run';

  @override
  String get detailGeneral => 'General';

  @override
  String get detailName => 'Name';

  @override
  String get detailDescription => 'Description';

  @override
  String get detailAgentId => 'Agent ID';

  @override
  String get detailEnabled => 'Enabled';

  @override
  String get detailTags => 'Tags';

  @override
  String get detailCreated => 'Created';

  @override
  String get detailUpdated => 'Updated';

  @override
  String get detailPrompts => 'Prompts';

  @override
  String get detailSystemPrompt => 'System Prompt';

  @override
  String get detailPrompt => 'Prompt';

  @override
  String get detailSchedule => 'Schedule';

  @override
  String get detailCron => 'Cron';

  @override
  String get detailHint => 'Hint';

  @override
  String get detailMaxRetries => 'Max Retries';

  @override
  String get detailRetryOnFailure => 'Retry on Failure';

  @override
  String get detailRetryDelay => 'Retry Delay';

  @override
  String detailRetryDelayValue(int minutes) {
    return '$minutes min';
  }

  @override
  String get detailExecuteImmediately => 'Execute Immediately';

  @override
  String get detailLlmOverride => 'LLM Override';

  @override
  String get detailProvider => 'Provider';

  @override
  String get detailModel => 'Model';

  @override
  String get detailBaseUrl => 'Base URL';

  @override
  String get detailTemperature => 'Temperature';

  @override
  String get detailMaxTokens => 'Max Tokens';

  @override
  String get detailApiKey => 'API Key';

  @override
  String detailBuiltInTools(int count) {
    return 'Built-in Tools ($count)';
  }

  @override
  String detailMcpTools(int count) {
    return 'MCP Tools ($count)';
  }

  @override
  String get detailProviders => 'Providers';

  @override
  String get detailEmail => 'Email';

  @override
  String get detailWebSearch => 'Web Search';

  @override
  String get detailNotifications => 'Notifications';

  @override
  String get detailEmailTo => 'Email To';

  @override
  String get detailSubject => 'Subject';

  @override
  String get detailSendWhen => 'Send When';

  @override
  String get detailPush => 'Push';

  @override
  String get detailPushTitle => 'Push Title';

  @override
  String get detailDownload => 'Download';

  @override
  String get detailDefaultDownloads => 'Default downloads';

  @override
  String get detailUpload => 'Upload';

  @override
  String get detailTotalRuns => 'Total Runs';

  @override
  String get detailConsecutiveFailures => 'Consecutive Failures';

  @override
  String get detailLastRun => 'Last Run';

  @override
  String get detailNextRun => 'Next Run';

  @override
  String get detailLastResult => 'Last Result';

  @override
  String get detailLastError => 'Last Error';

  @override
  String get userLog => 'User Log';

  @override
  String get executionLog => 'Execution Log';

  @override
  String get generatedFiles => 'Generated Files';

  @override
  String detailRunHistory(int count) {
    return 'Run History ($count)';
  }

  @override
  String detailDuration(int ms) {
    return 'Duration: ${ms}ms';
  }

  @override
  String get detailDurationNA => 'Duration: N/A';

  @override
  String get unknownError => 'Unknown error';

  @override
  String get viewResult => 'View result';

  @override
  String runDate(String date) {
    return 'Run $date';
  }

  @override
  String get result => 'Result:';

  @override
  String get error => 'Error:';

  @override
  String get configured => 'configured';

  @override
  String get allTools => 'all';

  @override
  String webSearchMaxResults(int count) {
    return 'max $count';
  }

  @override
  String get weatherSystemPrompt =>
      'You are a weather assistant. Use the weather tools to answer questions about current conditions, hourly and daily forecasts. Always include temperature, wind speed, and precipitation probability. When the user mentions a city, geocode it first, then fetch weather data. Present results concisely with units (°C, km/h, %). If no location is specified, use the configured default.';

  @override
  String get weatherDisplayName => 'Weather';

  @override
  String get weatherDescription =>
      'Fetch weather forecasts using Open-Meteo (free, no API key). Provides current conditions, hourly and daily forecasts.';

  @override
  String get documentDisplayName => 'Document Search';

  @override
  String get documentDescription =>
      'Search and index local documents (TXT, MD, DOCX, XLSX, PDF, CSV). Extracts text content and provides full-text search via DuckDB.';

  @override
  String get documentSystemPrompt =>
      'You are a document search assistant. Use the document tools to find and search through local documents. When the user asks about document content, use search_documents to find relevant files, then get_document_content to read specific documents. Present results clearly with file names and relevant excerpts. If no matches found, suggest broadening the search terms.';

  @override
  String get reindexDocuments => 'Reindex Documents';

  @override
  String get reindexDocumentsHint =>
      'Re-scan the folder and rebuild the search index.';

  @override
  String get reindexing => 'Indexing documents…';

  @override
  String reindexComplete(
    int count,
    int ms,
    String fileSizeKb,
    String indexSizeKb,
  ) {
    return 'Indexing complete: $count documents in ${ms}ms (files: $fileSizeKb KB, index: $indexSizeKb KB)';
  }

  @override
  String reindexFailed(String error) {
    return 'Indexing failed: $error';
  }

  @override
  String get indexingStart => 'Start Indexing';

  @override
  String get indexingStop => 'Stop';

  @override
  String indexingProgress(int current, int total) {
    return 'Indexing: $current/$total';
  }

  @override
  String indexingCurrentFile(String fileName) {
    return 'Current: $fileName';
  }

  @override
  String indexingCancelled(int count) {
    return 'Indexing cancelled after $count documents';
  }

  @override
  String get indexingStrategyNow => 'Index now (at initialization)';

  @override
  String get indexingStrategyLazy => 'Index before first search';

  @override
  String get indexEachTime => 'Index each time running the agent';

  @override
  String get indexFirstTime => 'Index first time';

  @override
  String get paramLabelRootPath => 'Root Path';

  @override
  String get paramLabelFileTypes => 'File Types';

  @override
  String get paramLabelIndexingStrategy => 'Indexing Strategy';

  @override
  String get paramLabelMaxDocuments => 'Max Documents';

  @override
  String get paramLabelWebsiteUrls => 'Website URLs';

  @override
  String get paramLabelMaxPages => 'Max Pages';

  @override
  String get paramLabelMaxResults => 'Max Results';

  @override
  String get paramLabelAccessToken => 'Access Token';

  @override
  String get paramLabelUserId => 'User ID';

  @override
  String get enumAuto => 'Auto';

  @override
  String get llmSettings => 'LLM Settings';

  @override
  String get llmSettingsSubtitle => 'Configure your AI provider & model';

  @override
  String get llmSettingsInfo =>
      'Configure your default LLM provider here. These settings are stored securely on your device and can be applied automatically when creating new tasks.';

  @override
  String get llmSettingsSaved => 'LLM settings saved';

  @override
  String llmSettingsSaveFailed(String error) {
    return 'Failed to save LLM settings: $error';
  }

  @override
  String get llmSettingsCleared => 'LLM settings cleared';

  @override
  String get llmClearSettingsTitle => 'Clear LLM Settings';

  @override
  String get llmClearSettingsMessage =>
      'This will remove all stored LLM credentials and configuration. Are you sure?';

  @override
  String get llmProviderLabel => 'Provider';

  @override
  String get llmModelLabel => 'Model';

  @override
  String get llmModelHint => 'e.g. gemini-2.5-flash';

  @override
  String get llmModelRequired => 'Model name is required';

  @override
  String get llmApiKeyLabel => 'API Key';

  @override
  String get llmApiKeyRequired => 'API key is required for this provider';

  @override
  String get llmApiKeyOptional => 'API key (optional)';

  @override
  String get llmBaseUrlLabel => 'Base URL';

  @override
  String get llmBaseUrlRequired => 'Base URL is required for this provider';

  @override
  String get llmUseNativeToolCall => 'Use native tool calling';

  @override
  String get llmUseNativeToolCallDescription =>
      'Use Ollama native tool calling capabilities instead of text-based tools.';

  @override
  String get llmUseSafeToolCall => 'Safe tool call mode';

  @override
  String get llmUseSafeToolCallDescription =>
      'Use grammar-constrained decoding to prevent malformed tool calls. Works even for models without native tool calling.';

  @override
  String get llmAdvancedSettings => 'Advanced Settings';

  @override
  String get llmTemperatureRange => 'Must be between 0.0 and 2.0';

  @override
  String get llmMaxTokensRange => 'Must be a positive number';

  @override
  String llmConfiguredStatus(String provider, String model) {
    return 'Configured: $provider / $model';
  }

  @override
  String get llmNotConfigured => 'Not configured';

  @override
  String get llmApplyDefaults => 'Apply default LLM settings';

  @override
  String get llmApplyDefaultsSubtitle =>
      'Fill the fields below from your saved LLM settings';

  @override
  String get llmDefaultsApplied => 'Default LLM settings applied';

  @override
  String get llmNoDefaults =>
      'No default LLM settings configured. Open LLM Settings from the home screen first.';

  @override
  String get llmAdvancedParams => 'Advanced Parameters';

  @override
  String get topK => 'Top K';

  @override
  String get topKTooltip =>
      'Limits vocabulary to the top-K tokens at each step. Lower = more deterministic. Range: 1–100.';

  @override
  String get topP => 'Top P';

  @override
  String get topPTooltip =>
      'Nucleus sampling cutoff. Lower = more focused output. Range: 0.0–1.0.';

  @override
  String get repeatPenalty => 'Repeat Penalty';

  @override
  String get repeatPenaltyTooltip =>
      'Penalizes repeating tokens. Values > 1.0 reduce repetition. Range: 0.5–2.0.';

  @override
  String get seed => 'Seed';

  @override
  String get seedTooltip =>
      'Random seed for reproducible outputs. Leave empty for random.';

  @override
  String get llm2EditableSettings => 'LLM 2 settings (editable for this task)';

  @override
  String get llm2SettingsOverrideHint =>
      'Pre-filled from your LLM 2 global settings. Changes apply only to this task.';

  @override
  String get interactiveMode => 'Interactive';

  @override
  String get interactiveModeTooltip => 'Test this task interactively';

  @override
  String get interactiveModeTitle => 'Interactive Mode';

  @override
  String get interactiveNoLlm =>
      'No LLM configured. Please configure LLM settings first.';

  @override
  String get interactiveConnecting => 'Connecting to MCP servers…';

  @override
  String get interactiveReady => 'Ready — type a message to test this task';

  @override
  String get interactiveSystemPromptLocked =>
      'System prompt locked from task config';

  @override
  String interactiveToolsAvailable(int count) {
    return '$count tools available';
  }

  @override
  String get interactiveNoTools => 'No tools configured';

  @override
  String get interactiveDisconnect => 'Disconnect & Close';

  @override
  String get sectionRawOutput => 'Raw Output';

  @override
  String get sectionOutputUser => 'Output User';

  @override
  String get sectionOutputFiles => 'Output Files';

  @override
  String get sectionSchedulerLog => 'Scheduler Log';

  @override
  String get noRawOutput => 'No raw output recorded for last run';

  @override
  String get noOutputUser => 'No user output recorded';

  @override
  String get noOutputFiles => 'No output files found';

  @override
  String get noSchedulerLog => 'No scheduler events recorded';

  @override
  String get schedulerEventScheduled => 'Scheduled';

  @override
  String get schedulerEventFired => 'Fired';

  @override
  String get schedulerEventStarted => 'Started';

  @override
  String get schedulerEventCompleted => 'Completed';

  @override
  String get schedulerEventFailed => 'Failed';

  @override
  String get schedulerEventSkipped => 'Skipped';

  @override
  String get schedulerEventAlarm => 'Alarm';

  @override
  String get schedulerActivity => 'Background Activity';

  @override
  String get schedulerActivityTitle => 'Background Activity · Last 48 h';

  @override
  String outputFileRunDir(String date) {
    return 'Run $date';
  }

  @override
  String get daysToLive => 'Days to keep output files';

  @override
  String get copyToClipboard => 'Copy to clipboard';

  @override
  String get copiedToClipboard => 'Copied to clipboard';

  @override
  String schedulerLogDetail(String detail) {
    return 'Detail: $detail';
  }

  @override
  String get tabChaining => 'Chaining';

  @override
  String get chainThisTaskSection => 'This Task';

  @override
  String get chainIsSubtask => 'Following agent mode';

  @override
  String get chainIsSubtaskHint =>
      'Only run when triggered by another agent — scheduler is ignored';

  @override
  String get chainSubtaskHint =>
      'Tip: prefix the target agent\'s prompt with the placeholder [task_result] to inject the triggering agent\'s output.';

  @override
  String get chainTriggerSection => 'Trigger Follow-up Agent';

  @override
  String get chainTriggerSectionHint =>
      'After this agent completes, optionally run another agent based on an LLM-evaluated condition.';

  @override
  String get chainWithCondition => 'With condition';

  @override
  String get chainWithConditionHint =>
      'Evaluate an LLM condition to pick between two follow-up agents.';

  @override
  String get chainDirectFollowup => 'Following agent (no condition)';

  @override
  String get chainDirectFollowupHint =>
      'Always trigger this agent after completion, passing [task_result].';

  @override
  String get stopAfterToolCall => 'Stop after tool call';

  @override
  String get stopAfterToolCallHint =>
      'Execute the tool call but don\'t send the result back to the LLM. The tool output becomes [task_result] for the following agent. With multiple steps: each step stops after its first tool call and the next step starts immediately.';

  @override
  String get chainCondition => 'Condition (LLM evaluated)';

  @override
  String get chainConditionHint => 'e.g. temperature is below 10 degrees';

  @override
  String get chainConditionHelper =>
      'Leave empty to always run the on-match task. In the target task\'s prompt, write [task_result] to inject this task\'s output.';

  @override
  String get chainOnMatch => 'If condition matches — run agent';

  @override
  String get chainOnNoMatch => 'If condition does NOT match — run agent (else)';

  @override
  String get chainTaskIdHint => 'Agent ID...';

  @override
  String get chainPickTask => 'Pick Following Agent';

  @override
  String get chainTaskResultHint =>
      'In any chained agent\'s prompt, write [task_result] to inject this agent\'s output.';

  @override
  String get noTasksAvailable => 'No agents available';

  @override
  String get noSubtasksAvailable =>
      'No following agents found. Enable \'Following agent mode\' on an agent first.';

  @override
  String get scheduleDisabledSubtask =>
      'Schedule inactive — this agent runs as a following agent and is triggered by another agent.';

  @override
  String get detailChainConfig => 'Agent Chaining';

  @override
  String get detailChainIsSubtask => 'Following agent mode';

  @override
  String get detailChainCondition => 'Condition';

  @override
  String get detailChainOnMatch => 'On match → task';

  @override
  String get detailChainOnNoMatch => 'On no match → task';

  @override
  String get wizardLlmDescription =>
      'Set provider, model, and API key. This is required before running tasks.';

  @override
  String get wizardOpenLlmSettings => 'Open LLM Settings';

  @override
  String get wizardDataSourcesDescription =>
      'Set up Gmail, IMAP, web search, and cloud storage credentials.';

  @override
  String get wizardOpenDataSources => 'Open Data Sources';

  @override
  String get wizardExternalToolsTitle => 'Remote MCP Servers';

  @override
  String get wizardExternalToolsDescription =>
      'Configure remote MCP servers accessible via HTTPS/SSE for use in your tasks.';

  @override
  String get wizardOpenExternalTools => 'Open Remote Servers';

  @override
  String get requiredLabel => 'Required';

  @override
  String get generalSection => 'General';

  @override
  String get generalSectionDescription =>
      'Theme, language, and backup settings.';

  @override
  String get themeLabel => 'Theme';

  @override
  String get themeToggleTooltip => 'Cycle: Dark → System → Light';

  @override
  String get languageLabel => 'Language';

  @override
  String get languageToggleTooltip => 'Toggle language';

  @override
  String get defaultOutputDir => 'Default Output Directory';

  @override
  String get defaultOutputDirDescription =>
      'Folder where task results, output logs and execution logs are always saved.';

  @override
  String get defaultOutputDirNotSet => 'Not set — using app documents folder';

  @override
  String get outputRetentionDays => 'Keep files for (days)';

  @override
  String get outputRetentionDaysDescription =>
      'Output folders older than this are automatically deleted.';

  @override
  String get backgroundCheckInterval => 'Background check interval';

  @override
  String get backgroundCheckIntervalDescription =>
      'How often the app wakes up in the background to check for scheduled tasks. A shorter interval is more responsive but uses slightly more battery.';

  @override
  String get exportBackup => 'Export';

  @override
  String get exportBackupDescription =>
      'Tasks & MCP server definitions (no API keys)';

  @override
  String get importBackup => 'Import';

  @override
  String get importBackupDescription =>
      'Restore tasks & MCP servers from a JSON file';

  @override
  String exportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String exportSavedToDownloads(String fileName) {
    return 'Saved to Downloads: $fileName';
  }

  @override
  String get exportSuccess => 'Backup exported successfully';

  @override
  String get phaseConfiguringLlm => 'Configuring LLM…';

  @override
  String get phaseConnectingExternalMcp => 'Connecting external MCP servers…';

  @override
  String get phaseConnectingInternalMcp => 'Initializing built-in tools…';

  @override
  String get chatSessionReset => 'Chat session reset and reinitialized';

  @override
  String get filterToolsHint => 'Filter tools…';

  @override
  String get noActiveTask => 'No active task. Please select a task first.';

  @override
  String get resetChatSessionTooltip => 'Reset chat session';

  @override
  String get chatStartHint => 'Send a message to start…';

  @override
  String get externalToolsScreenTitle => 'Remote MCP Servers';

  @override
  String get searchMcpCatalogTooltip => 'Search MCP servers';

  @override
  String get catalogUrlSaved => 'Catalog URL saved';

  @override
  String failedToSaveUrl(String error) {
    return 'Failed to save URL: $error';
  }

  @override
  String testingServerMsg(String name) {
    return 'Testing $name…';
  }

  @override
  String mcpTestSuccessMsg(String detail) {
    return 'MCP server test successful. $detail';
  }

  @override
  String mcpTestFailedMsg(String error) {
    return 'MCP test failed: $error';
  }

  @override
  String get serverUrlRequiredForTest => 'Server URL is required for test.';

  @override
  String get customServerAdded => 'Custom MCP server added';

  @override
  String failedToAddCustomServer(String error) {
    return 'Failed to add custom server: $error';
  }

  @override
  String get externalToolsGlobalInfo =>
      'Configure remote MCP servers accessible over HTTPS/SSE. Add any server that exposes an MCP endpoint — no local installation needed.';

  @override
  String get catalogUrlLabel => 'Catalog URL';

  @override
  String get saveUrlButton => 'Save URL';

  @override
  String get smitheryApiKeyLabel => 'Smithery API Key';

  @override
  String get smitheryApiKeyHint => 'Get yours at smithery.ai/account/api-keys';

  @override
  String get smitheryApiKeyHelper =>
      'Applied automatically to every server.smithery.ai endpoint that has no per-server key.';

  @override
  String get smitheryApiKeySaved => 'Smithery API key saved';

  @override
  String get saveSmitheryKeyButton => 'Save Smithery Key';

  @override
  String get addCustomMcpServerTitle => 'Add custom MCP server';

  @override
  String get mcpApiKeyBearerHint => 'Used as Bearer token';

  @override
  String get mcpApiKeyOptionalLabel => 'API Key (optional)';

  @override
  String get apiPasswordOptionalLabel => 'API Password (optional)';

  @override
  String get mcpApiKeyBearerHelper =>
      'For Smithery.ai servers: use your Smithery API key (smithery.ai → Settings → API Keys). It is sent as Authorization: Bearer with every request.';

  @override
  String get mcpApiPasswordOptionalHint => 'Optional auth fallback';

  @override
  String get testButton => 'Test';

  @override
  String get addButton => 'Add';

  @override
  String get selectedMcpServersTitle => 'Selected MCP Servers';

  @override
  String selectedServersCount(int count) {
    return '$count selected';
  }

  @override
  String get noExternalToolsYet =>
      'No remote MCP servers configured yet. Tap + to add a server URL.';

  @override
  String serverStatusTooltip(String status) {
    return 'Status: $status';
  }

  @override
  String get statusOnline => 'Online';

  @override
  String get statusOffline => 'Offline';

  @override
  String get statusUnknown => 'Unknown';

  @override
  String cloudMcpStatusLabel(String status) {
    return 'Cloud MCP · $status';
  }

  @override
  String get apiKeyConfiguredLabel => 'API key configured';

  @override
  String get apiKeyMissingLabel => 'API key missing';

  @override
  String get startPlayground => 'Start Playground';

  @override
  String get initialPromptHint =>
      'Optional first message — pre-filled in the chat input when Playground starts.';

  @override
  String get scriptLibraryTooltip => 'Script Library';

  @override
  String get scriptLibraryUpdated => 'Script library updated';

  @override
  String get toolboxChangesWarning => 'Changes will reset the current session';

  @override
  String get toolSelectionBuiltIn => 'Built-in';

  @override
  String get toolSelectionExternal => 'External MCP Servers';

  @override
  String get chatSendHint => 'Send a message to start…';

  @override
  String systemPromptTapToEdit(String label) {
    return '$label (tap to edit)';
  }

  @override
  String get websiteUrlLabel => 'Website URL';

  @override
  String get maxPagesLabel => 'Max pages';

  @override
  String get websiteUrlInvalid => 'Typed URL is invalid.';

  @override
  String get websiteUrlReady => 'Ready to add and index this URL.';

  @override
  String get websiteUrlAlreadyAdded =>
      'URL already selected or max websites reached.';

  @override
  String websiteUrlLimitHint(int maxPages) {
    return 'Add up to 3 sites. Indexed pages are stored in DuckDB. Max pages: $maxPages.';
  }

  @override
  String get addUrlButton => 'Add URL';

  @override
  String get noWebsitesSelected => 'No websites selected';

  @override
  String websitesSelectedCount(int count) {
    return '$count website(s) selected';
  }

  @override
  String get indexingActive => 'Indexing…';

  @override
  String get deleteScriptTitle => 'Delete script?';

  @override
  String deleteScriptConfirm(String name) {
    return 'Delete \"$name\"? This cannot be undone.';
  }

  @override
  String get shellScriptLibraryTitle => 'Shell Script Library';

  @override
  String get newScriptTooltip => 'New script';

  @override
  String get noScriptsYet => 'No scripts yet.';

  @override
  String get createFirstScriptHint => 'Tap + to create a new shell script.';

  @override
  String get createScriptButton => 'Create Script';

  @override
  String scriptDeletedMsg(String name) {
    return 'Deleted \"$name\"';
  }

  @override
  String get editScriptTooltip => 'Edit';

  @override
  String get deleteScriptTooltip => 'Delete';

  @override
  String get newShellScriptTitle => 'New Shell Script';

  @override
  String get editScriptDialogTitle => 'Edit Script';

  @override
  String get scriptNameLabel => 'Script name';

  @override
  String get scriptNameHint => 'e.g. disk_cleanup.sh';

  @override
  String get scriptDescriptionHint => 'What does this script do?';

  @override
  String get generateWithAiLabel => 'Generate with AI';

  @override
  String get generateScriptHint => 'Describe what the script should do…';

  @override
  String get describeForGeneration => 'Describe what the script should do.';

  @override
  String get withCommentsLabel => 'With comments';

  @override
  String get generateButton => 'Generate';

  @override
  String get noLlmForScript =>
      'No LLM configured. Set one in Settings or open a chat task first.';

  @override
  String get scriptContentLabel => 'Script content';

  @override
  String get insertIntoPromptButton => 'Insert into task prompt';

  @override
  String get insertedIntoPromptMsg => 'Inserted into task prompt.';

  @override
  String get scriptNameRequiredMsg => 'Script name is required.';

  @override
  String scriptSaveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String scriptGenerationFailed(String error) {
    return 'Generation failed: $error';
  }

  @override
  String get sshScriptLibraryNote =>
      'Scripts for SSH can be added or generated in the script library.';

  @override
  String get openButtonLabel => 'Open';

  @override
  String get externalMcpGlobalTitle => 'External MCP Servers (global)';

  @override
  String get externalMcpGlobalSubtitle =>
      'Toggle which global servers are active for this task.';

  @override
  String get browseDriveTooltip => 'Browse Drive';

  @override
  String get googleDriveLabel => 'Google Drive';

  @override
  String get noSubfoldersLabel => 'No subfolders';

  @override
  String get addGoogleDriveFolder => 'Add folder';

  @override
  String get selectRootLabel => 'Select root';

  @override
  String get selectHereLabel => 'Select here';

  @override
  String get generatePromptTopicHint => 'Topic (e.g. document search...)';

  @override
  String get generateLabel => 'Generate';

  @override
  String get applyLabel => 'Apply';

  @override
  String get systemPromptTitleLabel => 'System Prompt';

  @override
  String get taskPromptTitleLabel => 'Task Prompt';

  @override
  String get clear => 'Clear';

  @override
  String get execInitializing => 'Initializing task…';

  @override
  String get execSendingPrompt => 'Sending prompt to AI…';

  @override
  String execAiError(String error) {
    return 'AI error: $error';
  }

  @override
  String get execNoResponse => 'No response from LLM received.';

  @override
  String get execNoLlmResponse => 'Empty LLM response';

  @override
  String get execEmailSent => 'Email sent';

  @override
  String execEmailSentWithMsg(String message) {
    return 'Email sent: $message';
  }

  @override
  String execEmailError(String error) {
    return 'Email error: $error';
  }

  @override
  String get execCompleted => 'Execution completed.';

  @override
  String execError(String error) {
    return 'Error: $error';
  }

  @override
  String get execNotReady => 'Task runtime not ready. LLM configured?';

  @override
  String get execCheckChain => 'Checking chain condition…';

  @override
  String get execChainDone => 'Chain task executed.';

  @override
  String execChainError(String error) {
    return 'Chain error: $error';
  }

  @override
  String get applyAndReset => 'Apply & Reset';

  @override
  String get noToolsAvailable => 'No tools available';

  @override
  String websiteIndexComplete(int count, int ms) {
    return 'Website index complete: $count pages in ${ms}ms';
  }

  @override
  String get invalidWebsiteUrl => 'Invalid website URL';

  @override
  String get maxWebsitesReached => 'Maximum 3 websites allowed.';

  @override
  String get aboutTitle => 'About TealKit';

  @override
  String get userGuide => 'User Guide';

  @override
  String get privacyPolicy => 'Privacy Policy';

  @override
  String get psScriptLibraryTitle => 'PowerShell Script Library';

  @override
  String get psNewScriptTooltip => 'New PowerShell Script';

  @override
  String get psDeleteScriptTitle => 'Delete PowerShell Script';

  @override
  String psDeleteScriptConfirm(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String psScriptDeleted(String name) {
    return 'Deleted: $name';
  }

  @override
  String get psNoScriptsYet => 'No PowerShell scripts yet';

  @override
  String get psCreateFirstScriptHint => 'Create your first PowerShell script.';

  @override
  String get psCreateScriptButton => 'Create PowerShell Script';

  @override
  String get psNewScriptDialogTitle => 'New PowerShell Script';

  @override
  String get psEditScriptDialogTitle => 'Edit PowerShell Script';

  @override
  String get psScriptNameRequired => 'Script name is required.';

  @override
  String psSaveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get psNoScriptContent => 'No script content to test.';

  @override
  String get psWindowsOnlyTest =>
      'PowerShell test is only available on Windows.';

  @override
  String get psTestRunTitle => 'Test Run';

  @override
  String get psTestRunParams =>
      'Parameters (optional args passed to the script):';

  @override
  String get psTestRunFailed => 'Test Run Failed';

  @override
  String psTestOutput(int code) {
    return 'Test Output (exit code: $code)';
  }

  @override
  String get psRunsLocally => 'Runs locally on this Windows machine';

  @override
  String get psNoLlmConfigured => 'No LLM configured.';

  @override
  String psGenerationFailed(String error) {
    return 'Generation failed: $error';
  }

  @override
  String get psLoadSamplesTooltip => 'Load sample scripts';

  @override
  String psSamplesLoadedMsg(int count) {
    return '$count sample scripts added.';
  }

  @override
  String get vaultTitle => 'Settings Vault';

  @override
  String get vaultSubtitle =>
      'Export & import all settings, scripts and tasks — encrypted (.tkv)';

  @override
  String get vaultScreenTitle => 'Encrypted Settings Backup';

  @override
  String get vaultScreenDesc =>
      'Save all API keys, credentials and integrations to an AES-256 encrypted file.';

  @override
  String get vaultIncludedLabel => 'Included (selectable per export)';

  @override
  String get vaultIncludedText =>
      'Configuration: LLM / API keys / email / SSH / integrations\nScripts: JS  •  PowerShell  •  Python  •  SSH scripts\nTasks: all tasks with custom LLM, SSH settings & credentials';

  @override
  String get vaultExcludedLabel => 'Never included';

  @override
  String get vaultExcludedText =>
      'Conversation history  •  DuckDB document index';

  @override
  String get vaultExportSection => 'Export vault';

  @override
  String get vaultExportHint =>
      'Choose a folder, then set filename, password and which sections to include.';

  @override
  String get vaultChooseFolderExport => 'Choose Folder & Export';

  @override
  String get vaultEncrypting => 'Encrypting...';

  @override
  String vaultSaved(String name) {
    return 'Vault saved: $name';
  }

  @override
  String vaultExportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get vaultImportSection => 'Import vault';

  @override
  String get vaultImportHint =>
      'Select a .tkv file to restore credentials and settings.';

  @override
  String get vaultPickFileImport => 'Pick File & Restore';

  @override
  String get vaultDecrypting => 'Decrypting...';

  @override
  String vaultRestored(String name) {
    return 'Vault restored from $name';
  }

  @override
  String vaultImportFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get vaultDialogExportTitle => 'Export Vault';

  @override
  String get vaultDialogImportTitle => 'Import Vault';

  @override
  String get vaultDialogPassword => 'Password';

  @override
  String get vaultDialogPasswordMin => 'Min. 8 characters';

  @override
  String get vaultDialogPasswordHint => 'Vault password';

  @override
  String get vaultDialogPasswordLabel => 'Password (min. 8 chars)';

  @override
  String get vaultDialogConfirmPassword => 'Confirm password';

  @override
  String get vaultDialogEnterVaultPassword => 'Enter vault password';

  @override
  String get vaultDialogPasswordShort => 'At least 8 characters';

  @override
  String get vaultPasswordMismatch => 'Passwords do not match';

  @override
  String get vaultDialogFilenameLabel => 'Filename (.tkv)';

  @override
  String get vaultDialogEnterFilename => 'Enter a filename';

  @override
  String get vaultDialogIncludeLabel => 'Include in vault:';

  @override
  String get vaultDialogSelectRestore => 'Select what to restore:';

  @override
  String vaultDialogFrom(String name) {
    return 'From: $name';
  }

  @override
  String get vaultSectionConfiguration => 'Configuration';

  @override
  String get vaultSectionConfigurationDesc =>
      'LLM, API keys, email, SSH, integrations, all settings';

  @override
  String get vaultSectionScripts => 'Scripts';

  @override
  String get vaultSectionScriptsDesc => 'JS, PowerShell, Python, SSH scripts';

  @override
  String get vaultSectionScriptsMobileDesc =>
      'JS & SSH scripts (PowerShell/Python skipped on mobile)';

  @override
  String get vaultSectionTasks => 'Tasks';

  @override
  String get vaultSectionTasksDesc =>
      'All tasks with custom LLM, SSH settings & API keys';

  @override
  String get vaultSectionSessions => 'Playground Setups';

  @override
  String get vaultSectionSessionsDesc =>
      'Saved playground configurations (tools & prompts)';

  @override
  String get vaultSectionSkills => 'Tool Skills';

  @override
  String get vaultSectionSkillsDesc =>
      'LLM-generated procedural skill guides for MCP tools';

  @override
  String get vaultGreyedNotice =>
      'Greyed items are not present in this vault file.';

  @override
  String get vaultExportButton => 'Export';

  @override
  String get vaultRestoreButton => 'Restore';

  @override
  String get skillsScreenTitle => 'Tool Skills';

  @override
  String skillsScreenSubtitle(int count) {
    return '$count skills — enabled skills are injected into system prompts for tasks that use those tools.';
  }

  @override
  String get skillsEmptyHint =>
      'No skills yet.\nStart a chat to trigger auto-generation.';

  @override
  String get skillsFilterHint => 'Filter by tool or server…';

  @override
  String get skillsCustomBadge => 'Custom (manually edited)';

  @override
  String get skillsMenuRegenerate => 'Regenerate non-custom';

  @override
  String get skillsMenuRegenerateDesc =>
      'Re-generate auto skills, keep custom ones';

  @override
  String get skillsMenuRebuild => 'Rebuild (scan all tools)';

  @override
  String get skillsMenuRebuildDesc =>
      'Overwrite all  •  or  •  add missing only';

  @override
  String get skillsRebuildDialogTitle => 'Rebuild skills';

  @override
  String get skillsRebuildDialogDesc =>
      'Choose how to rebuild skills for all registered MCP tools.';

  @override
  String get skillsRebuildOverwriteTitle => 'Overwrite all skills';

  @override
  String get skillsRebuildOverwriteDesc =>
      'Delete every skill (including custom ones) and regenerate all from scratch.';

  @override
  String get skillsRebuildAddMissingTitle => 'Add missing skills only';

  @override
  String get skillsRebuildAddMissingDesc =>
      'Keep existing skills. Generate only for tools that have no skill yet.';

  @override
  String skillsEditDialogTitle(String toolName) {
    return 'Edit skill: $toolName';
  }

  @override
  String get skillsFullSkillLabel => 'Full skill (large models)';

  @override
  String get skillsSlmSkillLabel => 'SLM skill (small / embedded models)';

  @override
  String get docFileTypesLabel => 'File types to index';

  @override
  String get docFileTypesReset => 'Reset';

  @override
  String get docFileTypesAll => 'All';

  @override
  String get loadModelIntoApp => 'Load into app';

  @override
  String get unloadModel => 'Unload';

  @override
  String get modelLoadedInApp => 'In memory';

  @override
  String get loadingModelIntoApp => 'Loading into app…';

  @override
  String loadingModelProgress(int percent) {
    return 'Loading model… $percent%';
  }

  @override
  String get loadModelFailed => 'Failed to load model';

  @override
  String get execLoadingEmbeddedModel => 'Loading embedded model…';

  @override
  String get mcpRegistryInstallManuallyTooltip => 'Install manually';

  @override
  String get mcpManualInstallDialogTitle => 'Install MCP Server Manually';

  @override
  String get mcpManualInstallDialogSubtitle =>
      'Install an MCP server that is not listed in any registry.';

  @override
  String get mcpManualInstallNameLabel => 'Name';

  @override
  String get mcpManualInstallNameHint => 'e.g. Puppeteer MCP';

  @override
  String get mcpManualInstallUrlLabel => 'URL (optional)';

  @override
  String get mcpManualInstallUrlHint => 'https://github.com/…';

  @override
  String get mcpManualInstallTypeLabel => 'Type';

  @override
  String get mcpManualInstallMethodLabel => 'Method';

  @override
  String get mcpManualInstallTypeNodejs => 'Node.js';

  @override
  String get mcpManualInstallTypePython => 'Python';

  @override
  String get mcpManualInstallMethodNpm => 'npm install -g';

  @override
  String get mcpManualInstallMethodNpx => 'npx (on-demand)';

  @override
  String get mcpManualInstallMethodUvx => 'uvx (recommended)';

  @override
  String get mcpManualInstallMethodPip => 'pip install';

  @override
  String get mcpManualInstallPackageLabel => 'Package / server name';

  @override
  String get mcpManualInstallPackageHint => 'e.g. puppeteer-mcp-server';

  @override
  String get mcpManualInstallCommandLabel => 'Install command(s)';

  @override
  String get mcpManualInstallCommandHint =>
      'One command per line. Lines starting with # are comments.';

  @override
  String get mcpManualInstallRegenerateTooltip => 'Re-generate command';

  @override
  String get mcpManualInstallExecuteSaveButton => 'Execute & Save';

  @override
  String get mcpManualInstallRunningButton => 'Running…';

  @override
  String get mcpManualInstallDoneButton => 'Done';

  @override
  String get mcpManualInstallNoCommandsMsg =>
      'No install commands to run (on-demand launcher). Registering server…';

  @override
  String get mcpManualInstallSuccessMsg =>
      '✓ Install succeeded. Saving server…';

  @override
  String get mcpManualInstallSaveFailedPrefix => 'Save failed: ';

  @override
  String get mcpManualInstallCloseButton => 'Close';

  @override
  String get tooltipCopyMessage => 'Copy message';

  @override
  String get tooltipDownloadFile => 'Download file';

  @override
  String get tooltipCopyResult => 'Copy result';

  @override
  String get tooltipViewAllEmails => 'View all emails';

  @override
  String get tooltipViewAllFiles => 'View all files';

  @override
  String get tooltipViewFullScreen => 'View full screen';

  @override
  String get tooltipExportToPdf => 'Export to PDF';

  @override
  String get tooltipDownloadImage => 'Download image';

  @override
  String get tooltipShareFile => 'Share file';

  @override
  String get tooltipCopyFolderPath => 'Copy folder path';

  @override
  String get tooltipFileDetails => 'File details';

  @override
  String get tooltipCopyAll => 'Copy all';

  @override
  String get tooltipReadResource => 'Read resource';

  @override
  String get tooltipCopySchema => 'Copy schema';

  @override
  String get tooltipRefresh => 'Refresh';

  @override
  String get tooltipNewFolder => 'New folder';

  @override
  String get tooltipUploadFile => 'Upload file';

  @override
  String get tooltipUploadEnterPath => 'Upload (enter source path)';

  @override
  String get tooltipNoChanges => 'No changes';

  @override
  String get tooltipUploadToServer => 'Upload to server';

  @override
  String get tooltipRename => 'Rename';

  @override
  String get tooltipDeleteFile => 'Delete file';

  @override
  String get tooltipStopProcessing => 'Stop processing';

  @override
  String get tooltipExportToolList => 'Export tool list for model training';

  @override
  String get tooltipDiscoverTools => 'Discover tools';

  @override
  String get labelImageNotAvailable => 'Image not available';

  @override
  String get labelExcelFile => 'Excel file';

  @override
  String get labelWordDocument => 'Word document';

  @override
  String get labelNoContent => 'No content';

  @override
  String get labelNoResultYet => 'No result yet';

  @override
  String get labelNoMatchingEmails => 'No matching emails.';

  @override
  String get labelFilterEmails => 'Filter emails…';

  @override
  String get labelFileNotFound => 'File not found at this path';

  @override
  String get labelToolNoResultData =>
      'Tool executed but no result data available';

  @override
  String get labelToolCalledNoData =>
      'Tool called but no result data available';

  @override
  String get labelEmptyToolResult => '[Empty tool result]';

  @override
  String get labelEmailBodyEmpty => 'Email body is empty.';

  @override
  String get labelFailedParseEmail => 'Failed to parse email response.';

  @override
  String labelShowingEmailsOf(int count, int total) {
    return 'Showing $count of $total emails';
  }

  @override
  String labelEmailsCount(int count) {
    return 'Emails ($count)';
  }

  @override
  String get dialogNewFolder => 'New folder';

  @override
  String get dialogDeleteEmptyFolder => 'Delete empty folder';

  @override
  String get dialogDeleteFile => 'Delete file';

  @override
  String get dialogRenameFile => 'Rename file';

  @override
  String get dialogUploadFile => 'Upload file';

  @override
  String get dialogEditView => 'Edit / View';

  @override
  String get dialogDeleteConfirmPermanent => 'Permanently delete ';

  @override
  String get dialogSaveFile => 'Save File';

  @override
  String get dialogSaveToolList => 'Save tool list';

  @override
  String msgFileSaved(String path) {
    return 'File saved: $path';
  }

  @override
  String msgFailedDownload(String error) {
    return 'Failed to download file: $error';
  }

  @override
  String msgSavedToDownloads(String fileName) {
    return 'File saved to Downloads: $fileName';
  }

  @override
  String get msgFailedSaveFile => 'Failed to save file';

  @override
  String msgSavedToPath(String path) {
    return 'Saved to $path';
  }

  @override
  String get msgCopiedToClipboard => 'Copied to clipboard';

  @override
  String get msgToolResultCopied => 'Tool result copied to clipboard';

  @override
  String get msgToolCallCopied => 'Tool call copied to clipboard';

  @override
  String get msgPathCopied => 'Path copied';

  @override
  String get msgConversationReset => 'Conversation reset successfully';

  @override
  String msgImageSavedDownloads(String fileName) {
    return 'Image saved to Downloads: $fileName';
  }

  @override
  String get msgFailedSaveImage => 'Failed to save image';

  @override
  String get msgExportCancelled => 'Export cancelled';

  @override
  String msgExportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get msgSplitPromptInfo =>
      'Split into sub-prompts — separated by ++#++';

  @override
  String msgFailedAttachFile(String error) {
    return 'Failed to attach file: $error';
  }

  @override
  String msgFailedAttachImage(String error) {
    return 'Failed to attach image: $error';
  }

  @override
  String msgOfficeDocNotSupported(String name) {
    return 'Office documents ($name) are not supported by the AI.\n\nSupported formats:\n• Images (PNG, JPG, GIF, WebP)\n• PDF files\n• Text files\n\nPlease convert your Office document to PDF or copy the text content.';
  }

  @override
  String get msgEnterFilename => 'Please enter a filename';

  @override
  String msgFailedGeneratePdf(String error) {
    return 'Failed to generate PDF: $error';
  }

  @override
  String get msgNetworkImageExportNotSupported =>
      'Network image export not supported yet';

  @override
  String get labelFolderName => 'Folder name';

  @override
  String get labelSourcePath => 'Source path';

  @override
  String get labelNewName => 'New name';

  @override
  String get labelRemoteTarget => 'Remote target';

  @override
  String get labelSearchFiles => 'Search files...';

  @override
  String get labelNoFilesFound => 'No files found';

  @override
  String get labelFileName => 'Filename';

  @override
  String get labelEnterFilename => 'Enter filename';

  @override
  String get hintTypeMessage => 'Type a message...';

  @override
  String get hintAddCaption => 'Add a caption...';

  @override
  String get hintEnterSourcePath => '/home/user/file.txt';

  @override
  String get statusNoActiveTask => 'No active task';

  @override
  String get statusSelectTaskToSeeTools =>
      'Select a task to see\navailable tools';

  @override
  String get statusNoToolsAvailable => 'No tools available';

  @override
  String get statusNoResourcesAvailable => 'No resources available';

  @override
  String get statusLoadingTools => 'Loading tools...';

  @override
  String get statusConnectToSeeTools =>
      'Connect to MCP servers\nto see available tools';

  @override
  String statusNoToolsForServer(String server) {
    return 'No tools available for $server';
  }

  @override
  String get placeholderAllServers => 'All servers';

  @override
  String get labelIncludeServerTag => 'Include server tag';

  @override
  String get labelAllSelected => 'All selected';

  @override
  String get labelSelectAll => 'Select all';

  @override
  String get splitPromptInstruction =>
      'Split the user request into sequential sub-prompts. Join them with the separator ++#++ on its own line between steps. Each sub-prompt is a complete standalone instruction. Output ONLY the sub-prompts with the separator between them. No extra text.';

  @override
  String splitPromptHint(Object tool_result) {
    return 'Split prompt into sub-prompts\n\nTap to split:\n• Lines with \\n → split instantly\n• Tap ✦ to AI-split\n\nSeparator: ++#++ (on its own line)\nInject previous tool output: \$$tool_result';
  }

  @override
  String labelSplitFailed(String error) {
    return 'Split failed: $error';
  }

  @override
  String get renameAgentTitle => 'Rename Agent';

  @override
  String get agentNameLabel => 'Name';

  @override
  String get renameLabel => 'Rename';

  @override
  String get nextStepRoutingTitle => 'Next Step Routing';

  @override
  String get routingModeSequential => 'Sequential (Next agent)';

  @override
  String get routingModeConditional => 'Conditional (Branch)';

  @override
  String get routingModeScheduled => 'Scheduled (Independent)';

  @override
  String get agentScheduleTitle => 'Agent Schedule';

  @override
  String get schedulingDisabledWarning =>
      'Scheduling is disabled because this agent is called sequentially or conditionally by a previous one.';

  @override
  String get tagsLabel => 'Tags (comma separated)';

  @override
  String get removeAgentTooltip => 'Remove agent';

  @override
  String get addAgentTooltip => 'Add agent';

  @override
  String get routingModeLabel => 'Routing Mode';

  @override
  String conditionRuleHeader(int index) {
    return 'Condition Rule #$index';
  }

  @override
  String get removeConditionRuleTooltip => 'Remove condition rule';

  @override
  String get targetAgentLabel => 'Target Agent';

  @override
  String get addRoutingRuleLabel => 'Add Routing Rule';

  @override
  String get addAgentFirstWarning =>
      'Add another agent first to configure conditional routing.';

  @override
  String get operatorLabel => 'Operator';

  @override
  String get customExpressionLabel => 'Custom Expression';

  @override
  String get customExpressionHint => 'e.g. avg value > 5';

  @override
  String get valueLabel => 'Value';

  @override
  String get valueHint => 'Value to compare';

  @override
  String get agentScheduleHeader => 'Agent Schedule';

  @override
  String get operatorLess => 'Less (<)';

  @override
  String get operatorLessOrEquals => 'Less or Equals (<=)';

  @override
  String get operatorEquals => 'Equals (==)';

  @override
  String get operatorNotEqual => 'Not Equal (!=)';

  @override
  String get operatorGreaterThan => 'More (>)';

  @override
  String get operatorGreaterOrEquals => 'More or Equals (>=)';

  @override
  String get operatorContains => 'Contains';

  @override
  String get operatorNotContains => 'Not Contains';

  @override
  String get operatorCustom => 'Custom Expression';

  @override
  String get operatorLlmEval => 'Evaluated by LLM';

  @override
  String get llmConditionLabel => 'Condition to evaluate';

  @override
  String get llmConditionHint => 'e.g. battery voltage > 5';

  @override
  String get cancelExecution => 'Cancel execution';

  @override
  String get inactive => 'Inactive';

  @override
  String get noAgentLogs => 'No execution logs recorded for this workflow.';

  @override
  String agentLogsTitle(String name) {
    return 'Execution Logs: $name';
  }
}
