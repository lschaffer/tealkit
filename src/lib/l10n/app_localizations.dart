import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of L
/// returned by `L.of(context)`.
///
/// Applications need to include `L.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: L.localizationsDelegates,
///   supportedLocales: L.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the L.supportedLocales
/// property.
abstract class L {
  L(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static L of(BuildContext context) {
    return Localizations.of<L>(context, L)!;
  }

  static const LocalizationsDelegate<L> delegate = _LDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'TealKit'**
  String get appTitle;

  /// No description provided for @appSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your personal AI assistant'**
  String get appSubtitle;

  /// No description provided for @getStarted.
  ///
  /// In en, this message translates to:
  /// **'Get Started'**
  String get getStarted;

  /// No description provided for @viewLogs.
  ///
  /// In en, this message translates to:
  /// **'View Logs'**
  String get viewLogs;

  /// No description provided for @playground.
  ///
  /// In en, this message translates to:
  /// **'Playground'**
  String get playground;

  /// No description provided for @playgroundHint.
  ///
  /// In en, this message translates to:
  /// **'Try out prompts, tools and system instructions here before scheduling a workflow.'**
  String get playgroundHint;

  /// No description provided for @tasks.
  ///
  /// In en, this message translates to:
  /// **'Workflows'**
  String get tasks;

  /// No description provided for @firstStep.
  ///
  /// In en, this message translates to:
  /// **'First Step'**
  String get firstStep;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @configureLlmFirst.
  ///
  /// In en, this message translates to:
  /// **'Configure an LLM provider to unlock Playground and Workflows.'**
  String get configureLlmFirst;

  /// No description provided for @systemPrompt.
  ///
  /// In en, this message translates to:
  /// **'System Prompt'**
  String get systemPrompt;

  /// No description provided for @initialPrompt.
  ///
  /// In en, this message translates to:
  /// **'Initial Prompt'**
  String get initialPrompt;

  /// No description provided for @generatePrompt.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get generatePrompt;

  /// No description provided for @generateSystemPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a subject above, then tap ✦ to generate an AI-suggested system prompt.'**
  String get generateSystemPromptHint;

  /// No description provided for @promptSubject.
  ///
  /// In en, this message translates to:
  /// **'Subject (e.g. document search)'**
  String get promptSubject;

  /// No description provided for @selectTools.
  ///
  /// In en, this message translates to:
  /// **'Select Tools'**
  String get selectTools;

  /// No description provided for @toolsSelected.
  ///
  /// In en, this message translates to:
  /// **'{count} tools selected'**
  String toolsSelected(int count);

  /// No description provided for @resetChat.
  ///
  /// In en, this message translates to:
  /// **'Reset Chat'**
  String get resetChat;

  /// No description provided for @gmailSearch.
  ///
  /// In en, this message translates to:
  /// **'Gmail (Search)'**
  String get gmailSearch;

  /// No description provided for @imapSend.
  ///
  /// In en, this message translates to:
  /// **'SMTP (Send)'**
  String get imapSend;

  /// No description provided for @testVia.
  ///
  /// In en, this message translates to:
  /// **'Test via'**
  String get testVia;

  /// No description provided for @emailSearchGmail.
  ///
  /// In en, this message translates to:
  /// **'Use Gmail API for searching emails'**
  String get emailSearchGmail;

  /// No description provided for @emailSendImap.
  ///
  /// In en, this message translates to:
  /// **'Use SMTP for sending emails'**
  String get emailSendImap;

  /// No description provided for @taskScheduler.
  ///
  /// In en, this message translates to:
  /// **'Workflow Scheduler'**
  String get taskScheduler;

  /// No description provided for @newTask.
  ///
  /// In en, this message translates to:
  /// **'New Workflow'**
  String get newTask;

  /// No description provided for @editTask.
  ///
  /// In en, this message translates to:
  /// **'Edit Workflow'**
  String get editTask;

  /// No description provided for @createTask.
  ///
  /// In en, this message translates to:
  /// **'Create Workflow'**
  String get createTask;

  /// No description provided for @saveAsTask.
  ///
  /// In en, this message translates to:
  /// **'Save as Workflow'**
  String get saveAsTask;

  /// No description provided for @deleteTask.
  ///
  /// In en, this message translates to:
  /// **'Delete Workflow'**
  String get deleteTask;

  /// No description provided for @deleteTaskConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{name}\"?'**
  String deleteTaskConfirm(String name);

  /// No description provided for @taskCreated.
  ///
  /// In en, this message translates to:
  /// **'Workflow created'**
  String get taskCreated;

  /// No description provided for @taskUpdated.
  ///
  /// In en, this message translates to:
  /// **'Workflow updated'**
  String get taskUpdated;

  /// No description provided for @taskDeleted.
  ///
  /// In en, this message translates to:
  /// **'Workflow \"{name}\" deleted'**
  String taskDeleted(String name);

  /// No description provided for @failedToSave.
  ///
  /// In en, this message translates to:
  /// **'Failed to save: {error}'**
  String failedToSave(String error);

  /// No description provided for @failedToLoad.
  ///
  /// In en, this message translates to:
  /// **'Failed to load workflows: {error}'**
  String failedToLoad(String error);

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @filterScheduledOnly.
  ///
  /// In en, this message translates to:
  /// **'Scheduled only'**
  String get filterScheduledOnly;

  /// No description provided for @filterAllTasks.
  ///
  /// In en, this message translates to:
  /// **'All workflows'**
  String get filterAllTasks;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @reload.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get reload;

  /// No description provided for @enable.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get enable;

  /// No description provided for @disable.
  ///
  /// In en, this message translates to:
  /// **'Disable'**
  String get disable;

  /// No description provided for @enabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get enabled;

  /// No description provided for @disabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get disabled;

  /// No description provided for @yes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No description provided for @no.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// No description provided for @tabBasic.
  ///
  /// In en, this message translates to:
  /// **'Basic'**
  String get tabBasic;

  /// No description provided for @tabPrompts.
  ///
  /// In en, this message translates to:
  /// **'Prompts'**
  String get tabPrompts;

  /// No description provided for @tabSchedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get tabSchedule;

  /// No description provided for @tabLlm.
  ///
  /// In en, this message translates to:
  /// **'LLM'**
  String get tabLlm;

  /// No description provided for @tabMcp.
  ///
  /// In en, this message translates to:
  /// **'MCP'**
  String get tabMcp;

  /// No description provided for @tabBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get tabBuiltIn;

  /// No description provided for @tabData.
  ///
  /// In en, this message translates to:
  /// **'Data Sources'**
  String get tabData;

  /// No description provided for @tabNotify.
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get tabNotify;

  /// No description provided for @sectionGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get sectionGeneral;

  /// No description provided for @sectionPrompts.
  ///
  /// In en, this message translates to:
  /// **'Prompts'**
  String get sectionPrompts;

  /// No description provided for @sectionSchedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get sectionSchedule;

  /// No description provided for @sectionExecution.
  ///
  /// In en, this message translates to:
  /// **'Execution'**
  String get sectionExecution;

  /// No description provided for @taskName.
  ///
  /// In en, this message translates to:
  /// **'Workflow Name *'**
  String get taskName;

  /// No description provided for @taskNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Daily News Summary'**
  String get taskNameHint;

  /// No description provided for @nameRequired.
  ///
  /// In en, this message translates to:
  /// **'Name is required'**
  String get nameRequired;

  /// No description provided for @description.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get description;

  /// No description provided for @descriptionHint.
  ///
  /// In en, this message translates to:
  /// **'What does this task do?'**
  String get descriptionHint;

  /// No description provided for @agentId.
  ///
  /// In en, this message translates to:
  /// **'Agent ID'**
  String get agentId;

  /// No description provided for @agentIdHint.
  ///
  /// In en, this message translates to:
  /// **'Optional: link to a specific agent'**
  String get agentIdHint;

  /// No description provided for @tags.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get tags;

  /// No description provided for @tagsHint.
  ///
  /// In en, this message translates to:
  /// **'comma separated: news, daily, summary'**
  String get tagsHint;

  /// No description provided for @taskEnabledSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Workflow will run on schedule when enabled'**
  String get taskEnabledSubtitle;

  /// No description provided for @systemPromptHint.
  ///
  /// In en, this message translates to:
  /// **'You are a helpful assistant...'**
  String get systemPromptHint;

  /// No description provided for @taskPrompt.
  ///
  /// In en, this message translates to:
  /// **'Workflow Prompt *'**
  String get taskPrompt;

  /// No description provided for @taskPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Summarize top AI news from the last 24h...'**
  String get taskPromptHint;

  /// No description provided for @promptRequired.
  ///
  /// In en, this message translates to:
  /// **'Prompt is required'**
  String get promptRequired;

  /// No description provided for @cronSchedule.
  ///
  /// In en, this message translates to:
  /// **'Cron Schedule'**
  String get cronSchedule;

  /// No description provided for @cronExpression.
  ///
  /// In en, this message translates to:
  /// **'Cron Expression *'**
  String get cronExpression;

  /// No description provided for @cronFormat.
  ///
  /// In en, this message translates to:
  /// **'Format: minute hour day month weekday'**
  String get cronFormat;

  /// No description provided for @cronRequired.
  ///
  /// In en, this message translates to:
  /// **'Cron expression required'**
  String get cronRequired;

  /// No description provided for @scheduleDescription.
  ///
  /// In en, this message translates to:
  /// **'Schedule Description'**
  String get scheduleDescription;

  /// No description provided for @scheduleDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Every day at 8:00'**
  String get scheduleDescriptionHint;

  /// No description provided for @cronEveryMinute.
  ///
  /// In en, this message translates to:
  /// **'Every minute'**
  String get cronEveryMinute;

  /// No description provided for @cronHourly.
  ///
  /// In en, this message translates to:
  /// **'Hourly'**
  String get cronHourly;

  /// No description provided for @cronDaily8am.
  ///
  /// In en, this message translates to:
  /// **'Daily 8am'**
  String get cronDaily8am;

  /// No description provided for @cronDaily6pm.
  ///
  /// In en, this message translates to:
  /// **'Daily 6pm'**
  String get cronDaily6pm;

  /// No description provided for @cronMonFri9am.
  ///
  /// In en, this message translates to:
  /// **'Mon-Fri 9am'**
  String get cronMonFri9am;

  /// No description provided for @cronWeeklyMon.
  ///
  /// In en, this message translates to:
  /// **'Weekly (Mon)'**
  String get cronWeeklyMon;

  /// No description provided for @cronMonthly1st.
  ///
  /// In en, this message translates to:
  /// **'Monthly 1st'**
  String get cronMonthly1st;

  /// No description provided for @schedulePickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get schedulePickerTitle;

  /// No description provided for @scheduleMinutes.
  ///
  /// In en, this message translates to:
  /// **'Minutes'**
  String get scheduleMinutes;

  /// No description provided for @scheduleHourly.
  ///
  /// In en, this message translates to:
  /// **'Hourly'**
  String get scheduleHourly;

  /// No description provided for @scheduleDaily.
  ///
  /// In en, this message translates to:
  /// **'Daily'**
  String get scheduleDaily;

  /// No description provided for @scheduleWeekly.
  ///
  /// In en, this message translates to:
  /// **'Weekly'**
  String get scheduleWeekly;

  /// No description provided for @scheduleMonthly.
  ///
  /// In en, this message translates to:
  /// **'Monthly'**
  String get scheduleMonthly;

  /// No description provided for @scheduleCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get scheduleCustom;

  /// No description provided for @scheduleEveryNMinutes.
  ///
  /// In en, this message translates to:
  /// **'Every {n} minutes'**
  String scheduleEveryNMinutes(int n);

  /// No description provided for @scheduleEveryNHours.
  ///
  /// In en, this message translates to:
  /// **'Every {n} hours'**
  String scheduleEveryNHours(int n);

  /// No description provided for @scheduleAtHour.
  ///
  /// In en, this message translates to:
  /// **'At hour'**
  String get scheduleAtHour;

  /// No description provided for @scheduleAtMinute.
  ///
  /// In en, this message translates to:
  /// **'At minute'**
  String get scheduleAtMinute;

  /// No description provided for @scheduleOnDays.
  ///
  /// In en, this message translates to:
  /// **'On days'**
  String get scheduleOnDays;

  /// No description provided for @scheduleOnDayOfMonth.
  ///
  /// In en, this message translates to:
  /// **'On day of month'**
  String get scheduleOnDayOfMonth;

  /// No description provided for @scheduleMon.
  ///
  /// In en, this message translates to:
  /// **'Mon'**
  String get scheduleMon;

  /// No description provided for @scheduleTue.
  ///
  /// In en, this message translates to:
  /// **'Tue'**
  String get scheduleTue;

  /// No description provided for @scheduleWed.
  ///
  /// In en, this message translates to:
  /// **'Wed'**
  String get scheduleWed;

  /// No description provided for @scheduleThu.
  ///
  /// In en, this message translates to:
  /// **'Thu'**
  String get scheduleThu;

  /// No description provided for @scheduleFri.
  ///
  /// In en, this message translates to:
  /// **'Fri'**
  String get scheduleFri;

  /// No description provided for @scheduleSat.
  ///
  /// In en, this message translates to:
  /// **'Sat'**
  String get scheduleSat;

  /// No description provided for @scheduleSun.
  ///
  /// In en, this message translates to:
  /// **'Sun'**
  String get scheduleSun;

  /// No description provided for @errorHandling.
  ///
  /// In en, this message translates to:
  /// **'Error Handling'**
  String get errorHandling;

  /// No description provided for @maxRetries.
  ///
  /// In en, this message translates to:
  /// **'Max Retries'**
  String get maxRetries;

  /// No description provided for @retryDelay.
  ///
  /// In en, this message translates to:
  /// **'Retry Delay (min)'**
  String get retryDelay;

  /// No description provided for @timeout.
  ///
  /// In en, this message translates to:
  /// **'Timeout (sec)'**
  String get timeout;

  /// No description provided for @retryOnFailure.
  ///
  /// In en, this message translates to:
  /// **'Retry on Failure'**
  String get retryOnFailure;

  /// No description provided for @executeImmediately.
  ///
  /// In en, this message translates to:
  /// **'Execute Immediately'**
  String get executeImmediately;

  /// No description provided for @llmOverride.
  ///
  /// In en, this message translates to:
  /// **'LLM Override'**
  String get llmOverride;

  /// No description provided for @overrideDefaultLlm.
  ///
  /// In en, this message translates to:
  /// **'Override default LLM config'**
  String get overrideDefaultLlm;

  /// No description provided for @overrideDefaultLlmSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use a specific model/provider for this task'**
  String get overrideDefaultLlmSubtitle;

  /// No description provided for @provider.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get provider;

  /// No description provided for @model.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get model;

  /// No description provided for @modelHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. gpt-4o, gemini-2.5-flash'**
  String get modelHint;

  /// No description provided for @apiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get apiKey;

  /// No description provided for @apiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'sk-...'**
  String get apiKeyHint;

  /// No description provided for @apiKeyNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get apiKeyNotSet;

  /// No description provided for @baseUrl.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get baseUrl;

  /// No description provided for @baseUrlHint.
  ///
  /// In en, this message translates to:
  /// **'http://localhost:11434 (for Ollama)'**
  String get baseUrlHint;

  /// No description provided for @temperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get temperature;

  /// No description provided for @maxTokens.
  ///
  /// In en, this message translates to:
  /// **'Max Tokens'**
  String get maxTokens;

  /// No description provided for @mcpServers.
  ///
  /// In en, this message translates to:
  /// **'MCP Servers'**
  String get mcpServers;

  /// No description provided for @addServer.
  ///
  /// In en, this message translates to:
  /// **'Add Server'**
  String get addServer;

  /// No description provided for @editMcpServer.
  ///
  /// In en, this message translates to:
  /// **'Edit MCP Server'**
  String get editMcpServer;

  /// No description provided for @addMcpServer.
  ///
  /// In en, this message translates to:
  /// **'Add MCP Server'**
  String get addMcpServer;

  /// No description provided for @noMcpServers.
  ///
  /// In en, this message translates to:
  /// **'No MCP servers configured'**
  String get noMcpServers;

  /// No description provided for @noMcpServersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add a server to give this task access to external tools'**
  String get noMcpServersSubtitle;

  /// No description provided for @discoverTools.
  ///
  /// In en, this message translates to:
  /// **'Discover tools'**
  String get discoverTools;

  /// No description provided for @specUrl.
  ///
  /// In en, this message translates to:
  /// **'Spec URL'**
  String get specUrl;

  /// No description provided for @apiPassword.
  ///
  /// In en, this message translates to:
  /// **'API Password'**
  String get apiPassword;

  /// No description provided for @serverUrl.
  ///
  /// In en, this message translates to:
  /// **'Server URL *'**
  String get serverUrl;

  /// No description provided for @serverUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://example.com/myserver'**
  String get serverUrlHint;

  /// No description provided for @urlRequired.
  ///
  /// In en, this message translates to:
  /// **'URL is required'**
  String get urlRequired;

  /// No description provided for @mcpEndpoint.
  ///
  /// In en, this message translates to:
  /// **'MCP Endpoint'**
  String get mcpEndpoint;

  /// No description provided for @mcpEndpointHint.
  ///
  /// In en, this message translates to:
  /// **'/mcp'**
  String get mcpEndpointHint;

  /// No description provided for @mcpEndpointHelper.
  ///
  /// In en, this message translates to:
  /// **'JSON-RPC endpoint path (default: /mcp)'**
  String get mcpEndpointHelper;

  /// No description provided for @specificationUrl.
  ///
  /// In en, this message translates to:
  /// **'Specification URL'**
  String get specificationUrl;

  /// No description provided for @specificationUrlHint.
  ///
  /// In en, this message translates to:
  /// **'Optional: OpenAPI/MCP spec endpoint'**
  String get specificationUrlHint;

  /// No description provided for @serverName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get serverName;

  /// No description provided for @serverNameHint.
  ///
  /// In en, this message translates to:
  /// **'My MCP Server'**
  String get serverNameHint;

  /// No description provided for @optional.
  ///
  /// In en, this message translates to:
  /// **'Optional'**
  String get optional;

  /// No description provided for @enabledTools.
  ///
  /// In en, this message translates to:
  /// **'Enabled tools:'**
  String get enabledTools;

  /// No description provided for @discovered.
  ///
  /// In en, this message translates to:
  /// **'Discovered:'**
  String get discovered;

  /// No description provided for @toolsCount.
  ///
  /// In en, this message translates to:
  /// **'Tools ({count})'**
  String toolsCount(int count);

  /// No description provided for @promptsCount.
  ///
  /// In en, this message translates to:
  /// **'Prompts ({count})'**
  String promptsCount(int count);

  /// No description provided for @resourcesCount.
  ///
  /// In en, this message translates to:
  /// **'Resources ({count})'**
  String resourcesCount(int count);

  /// No description provided for @toolsChip.
  ///
  /// In en, this message translates to:
  /// **'{count} tools'**
  String toolsChip(int count);

  /// No description provided for @builtInMcpServers.
  ///
  /// In en, this message translates to:
  /// **'Built-in MCP Servers'**
  String get builtInMcpServers;

  /// No description provided for @builtInMcpSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Internal tools that run locally in the app — no external server needed.'**
  String get builtInMcpSubtitle;

  /// No description provided for @addToTask.
  ///
  /// In en, this message translates to:
  /// **'Add to task'**
  String get addToTask;

  /// No description provided for @tapToEnable.
  ///
  /// In en, this message translates to:
  /// **'Tap to enable this built-in MCP'**
  String get tapToEnable;

  /// No description provided for @typeLabel.
  ///
  /// In en, this message translates to:
  /// **'Type: {type}'**
  String typeLabel(String type);

  /// No description provided for @configuration.
  ///
  /// In en, this message translates to:
  /// **'Configuration'**
  String get configuration;

  /// No description provided for @mcpSystemPrompt.
  ///
  /// In en, this message translates to:
  /// **'System Prompt'**
  String get mcpSystemPrompt;

  /// No description provided for @mcpSystemPromptHelper.
  ///
  /// In en, this message translates to:
  /// **'Instructs the LLM how to use this MCP\'s tools effectively.'**
  String get mcpSystemPromptHelper;

  /// No description provided for @mcpSystemPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Enter system prompt…'**
  String get mcpSystemPromptHint;

  /// No description provided for @resetToDefault.
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get resetToDefault;

  /// No description provided for @appendMainSystemPrompt.
  ///
  /// In en, this message translates to:
  /// **'Append main system prompt'**
  String get appendMainSystemPrompt;

  /// No description provided for @mainSystemPromptAppended.
  ///
  /// In en, this message translates to:
  /// **'Main system prompt appended'**
  String get mainSystemPromptAppended;

  /// No description provided for @noMainSystemPrompt.
  ///
  /// In en, this message translates to:
  /// **'No main system prompt set for this task'**
  String get noMainSystemPrompt;

  /// No description provided for @availableTools.
  ///
  /// In en, this message translates to:
  /// **'Available Tools'**
  String get availableTools;

  /// No description provided for @noBuiltInMcp.
  ///
  /// In en, this message translates to:
  /// **'No built-in MCP servers available.'**
  String get noBuiltInMcp;

  /// No description provided for @globalMcpServersNote.
  ///
  /// In en, this message translates to:
  /// **'These servers are configured globally in External Tools settings and are always available to this task.'**
  String get globalMcpServersNote;

  /// No description provided for @noGlobalMcpServers.
  ///
  /// In en, this message translates to:
  /// **'No external MCP servers configured. Add them in External Tools settings.'**
  String get noGlobalMcpServers;

  /// No description provided for @defaultPrefix.
  ///
  /// In en, this message translates to:
  /// **'Default: {value}'**
  String defaultPrefix(String value);

  /// No description provided for @dataSources.
  ///
  /// In en, this message translates to:
  /// **'Data Sources'**
  String get dataSources;

  /// No description provided for @dataSourcesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enable or disable data sources for this task. Credentials are configured globally in the Data Sources settings on the start screen.'**
  String get dataSourcesSubtitle;

  /// No description provided for @dataSourcesGlobalSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Configure global credentials for data sources. These are stored securely on your device.'**
  String get dataSourcesGlobalSubtitle;

  /// No description provided for @dataSourcesNotConfiguredHint.
  ///
  /// In en, this message translates to:
  /// **'Not configured – set up in Data Sources on the start screen'**
  String get dataSourcesNotConfiguredHint;

  /// No description provided for @dataSourcesConfiguredHint.
  ///
  /// In en, this message translates to:
  /// **'Credentials configured globally'**
  String get dataSourcesConfiguredHint;

  /// No description provided for @dataSourcesSettingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Data source settings saved'**
  String get dataSourcesSettingsSaved;

  /// No description provided for @dataSourcesSettingsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to save: {error}'**
  String dataSourcesSettingsSaveFailed(String error);

  /// No description provided for @dataSourcesSettingsCleared.
  ///
  /// In en, this message translates to:
  /// **'All data source settings cleared'**
  String get dataSourcesSettingsCleared;

  /// No description provided for @dataSourcesClearTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear all data source settings?'**
  String get dataSourcesClearTitle;

  /// No description provided for @dataSourcesClearMessage.
  ///
  /// In en, this message translates to:
  /// **'This will remove all stored credentials. Data sources will need to be reconfigured.'**
  String get dataSourcesClearMessage;

  /// No description provided for @dataSourcesConfigured.
  ///
  /// In en, this message translates to:
  /// **'{count} data source(s) configured'**
  String dataSourcesConfigured(int count);

  /// No description provided for @dataSourcesNone.
  ///
  /// In en, this message translates to:
  /// **'No data sources configured'**
  String get dataSourcesNone;

  /// No description provided for @emailProvider.
  ///
  /// In en, this message translates to:
  /// **'Email Provider'**
  String get emailProvider;

  /// No description provided for @emailProviderSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Read and search emails, send notifications'**
  String get emailProviderSubtitle;

  /// No description provided for @imapProvider.
  ///
  /// In en, this message translates to:
  /// **'IMAP (generic)'**
  String get imapProvider;

  /// No description provided for @imapHost.
  ///
  /// In en, this message translates to:
  /// **'IMAP Host (inbound)'**
  String get imapHost;

  /// No description provided for @imapHostHint.
  ///
  /// In en, this message translates to:
  /// **'imap.example.com'**
  String get imapHostHint;

  /// No description provided for @imapPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get imapPort;

  /// No description provided for @imapUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get imapUsername;

  /// No description provided for @imapPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get imapPassword;

  /// No description provided for @imapUseSsl.
  ///
  /// In en, this message translates to:
  /// **'Use SSL/TLS'**
  String get imapUseSsl;

  /// No description provided for @smtpHost.
  ///
  /// In en, this message translates to:
  /// **'SMTP Host (outgoing)'**
  String get smtpHost;

  /// No description provided for @smtpHostHint.
  ///
  /// In en, this message translates to:
  /// **'smtp.example.com'**
  String get smtpHostHint;

  /// No description provided for @smtpPort.
  ///
  /// In en, this message translates to:
  /// **'SMTP Port'**
  String get smtpPort;

  /// No description provided for @smtpSender.
  ///
  /// In en, this message translates to:
  /// **'Sender Email'**
  String get smtpSender;

  /// No description provided for @smtpSenderHint.
  ///
  /// In en, this message translates to:
  /// **'your-email@example.com'**
  String get smtpSenderHint;

  /// No description provided for @notificationEmail.
  ///
  /// In en, this message translates to:
  /// **'Use for task notifications'**
  String get notificationEmail;

  /// No description provided for @notificationEmailHint.
  ///
  /// In en, this message translates to:
  /// **'Send task outputs via this email'**
  String get notificationEmailHint;

  /// No description provided for @googleServices.
  ///
  /// In en, this message translates to:
  /// **'Google Services'**
  String get googleServices;

  /// No description provided for @googleServicesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Gmail search and Google Drive access'**
  String get googleServicesSubtitle;

  /// No description provided for @imapSmtpEmail.
  ///
  /// In en, this message translates to:
  /// **'Email Send (SMTP)'**
  String get imapSmtpEmail;

  /// No description provided for @imapSmtpEmailSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Send emails via external mail server'**
  String get imapSmtpEmailSubtitle;

  /// No description provided for @cloudStorage.
  ///
  /// In en, this message translates to:
  /// **'Cloud Storage'**
  String get cloudStorage;

  /// No description provided for @cloudStorageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Access files from Google Drive or OneDrive'**
  String get cloudStorageSubtitle;

  /// No description provided for @googleDrive.
  ///
  /// In en, this message translates to:
  /// **'Google Drive'**
  String get googleDrive;

  /// No description provided for @oneDrive.
  ///
  /// In en, this message translates to:
  /// **'Microsoft OneDrive'**
  String get oneDrive;

  /// No description provided for @oneDriveSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Access files from Microsoft OneDrive'**
  String get oneDriveSubtitle;

  /// No description provided for @oneDriveClientId.
  ///
  /// In en, this message translates to:
  /// **'Application (Client) ID'**
  String get oneDriveClientId;

  /// No description provided for @oneDriveClientIdHint.
  ///
  /// In en, this message translates to:
  /// **'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'**
  String get oneDriveClientIdHint;

  /// No description provided for @oneDriveTenantId.
  ///
  /// In en, this message translates to:
  /// **'Directory (Tenant) ID'**
  String get oneDriveTenantId;

  /// No description provided for @oneDriveTenantIdHint.
  ///
  /// In en, this message translates to:
  /// **'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'**
  String get oneDriveTenantIdHint;

  /// No description provided for @gmail.
  ///
  /// In en, this message translates to:
  /// **'Google Mail (Gmail)'**
  String get gmail;

  /// No description provided for @gmailSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Read emails via Gmail API with OAuth2'**
  String get gmailSubtitle;

  /// No description provided for @gmailSetup.
  ///
  /// In en, this message translates to:
  /// **'You need a Google Cloud project with Gmail API enabled and OAuth2 credentials (Desktop app type).'**
  String get gmailSetup;

  /// No description provided for @oauthClientId.
  ///
  /// In en, this message translates to:
  /// **'OAuth2 Client ID *'**
  String get oauthClientId;

  /// No description provided for @oauthClientIdHint.
  ///
  /// In en, this message translates to:
  /// **'123456-abc.apps.googleusercontent.com'**
  String get oauthClientIdHint;

  /// No description provided for @oauthClientSecret.
  ///
  /// In en, this message translates to:
  /// **'OAuth2 Client Secret *'**
  String get oauthClientSecret;

  /// No description provided for @oauthClientSecretHint.
  ///
  /// In en, this message translates to:
  /// **'GOCSPX-...'**
  String get oauthClientSecretHint;

  /// No description provided for @authorizeGoogle.
  ///
  /// In en, this message translates to:
  /// **'Authorize with Google'**
  String get authorizeGoogle;

  /// No description provided for @oauthAuthorizationCode.
  ///
  /// In en, this message translates to:
  /// **'Authorization Code'**
  String get oauthAuthorizationCode;

  /// No description provided for @oauthAuthorizationCodeHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the code or the full callback URL (http://localhost/?code=...)'**
  String get oauthAuthorizationCodeHint;

  /// No description provided for @exchangeAuthorizationCode.
  ///
  /// In en, this message translates to:
  /// **'Exchange Code'**
  String get exchangeAuthorizationCode;

  /// No description provided for @oauthOpenSuccess.
  ///
  /// In en, this message translates to:
  /// **'Google consent opened. After login, copy from browser URL (code=...) or paste the full callback URL here.'**
  String get oauthOpenSuccess;

  /// No description provided for @oauthOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open Google consent screen.'**
  String get oauthOpenFailed;

  /// No description provided for @oauthCodeRequired.
  ///
  /// In en, this message translates to:
  /// **'Authorization code is required.'**
  String get oauthCodeRequired;

  /// No description provided for @oauthExchangeSuccess.
  ///
  /// In en, this message translates to:
  /// **'Google OAuth connected successfully.'**
  String get oauthExchangeSuccess;

  /// No description provided for @oauthExchangeFailed.
  ///
  /// In en, this message translates to:
  /// **'Google OAuth exchange failed: {error}'**
  String oauthExchangeFailed(String error);

  /// No description provided for @oauthTokenStatusReady.
  ///
  /// In en, this message translates to:
  /// **'OAuth connected for {email}, token expires at {expiry}'**
  String oauthTokenStatusReady(String email, String expiry);

  /// No description provided for @oauthTokenStatusMissing.
  ///
  /// In en, this message translates to:
  /// **'OAuth token not connected yet.'**
  String get oauthTokenStatusMissing;

  /// No description provided for @sendTestEmail.
  ///
  /// In en, this message translates to:
  /// **'Send Test Email'**
  String get sendTestEmail;

  /// No description provided for @testEmailRecipient.
  ///
  /// In en, this message translates to:
  /// **'Test Recipient'**
  String get testEmailRecipient;

  /// No description provided for @testEmailRecipientRequired.
  ///
  /// In en, this message translates to:
  /// **'Test recipient email is required.'**
  String get testEmailRecipientRequired;

  /// No description provided for @testEmailSent.
  ///
  /// In en, this message translates to:
  /// **'Test email sent successfully.'**
  String get testEmailSent;

  /// No description provided for @testEmailFailed.
  ///
  /// In en, this message translates to:
  /// **'Test email failed: {error}'**
  String testEmailFailed(String error);

  /// No description provided for @oauthNotYet.
  ///
  /// In en, this message translates to:
  /// **'OAuth2 flow not yet implemented — save credentials first'**
  String get oauthNotYet;

  /// No description provided for @na.
  ///
  /// In en, this message translates to:
  /// **'N/A'**
  String get na;

  /// No description provided for @webSearch.
  ///
  /// In en, this message translates to:
  /// **'Web Search'**
  String get webSearch;

  /// No description provided for @webSearchSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Search the web via Google or DuckDuckGo'**
  String get webSearchSubtitle;

  /// No description provided for @searchProvider.
  ///
  /// In en, this message translates to:
  /// **'Search Provider'**
  String get searchProvider;

  /// No description provided for @customProvider.
  ///
  /// In en, this message translates to:
  /// **'Custom Provider'**
  String get customProvider;

  /// No description provided for @customProviderSetup.
  ///
  /// In en, this message translates to:
  /// **'Custom provider setup'**
  String get customProviderSetup;

  /// No description provided for @customProviderName.
  ///
  /// In en, this message translates to:
  /// **'Provider name'**
  String get customProviderName;

  /// No description provided for @customProviderNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Internal Search API'**
  String get customProviderNameHint;

  /// No description provided for @customProviderEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Provider endpoint URL'**
  String get customProviderEndpoint;

  /// No description provided for @customProviderEndpointHint.
  ///
  /// In en, this message translates to:
  /// **'https://example.com/search'**
  String get customProviderEndpointHint;

  /// No description provided for @serperProvider.
  ///
  /// In en, this message translates to:
  /// **'Serper.dev'**
  String get serperProvider;

  /// No description provided for @serperSetup.
  ///
  /// In en, this message translates to:
  /// **'Serper.dev setup'**
  String get serperSetup;

  /// No description provided for @serperApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'serper_... or your API key'**
  String get serperApiKeyHint;

  /// No description provided for @serpApiProvider.
  ///
  /// In en, this message translates to:
  /// **'SerpApi (Google Search)'**
  String get serpApiProvider;

  /// No description provided for @serpApiSetup.
  ///
  /// In en, this message translates to:
  /// **'SerpApi uses the Google Search API. Requires an API key from serpapi.com.'**
  String get serpApiSetup;

  /// No description provided for @serpApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Your SerpApi API key'**
  String get serpApiKeyHint;

  /// No description provided for @duckDuckGo.
  ///
  /// In en, this message translates to:
  /// **'DuckDuckGo (no API key needed)'**
  String get duckDuckGo;

  /// No description provided for @googleCustomSearch.
  ///
  /// In en, this message translates to:
  /// **'Google Custom Search'**
  String get googleCustomSearch;

  /// No description provided for @googleSearchSetup.
  ///
  /// In en, this message translates to:
  /// **'Requires a Google Cloud API Key and a Programmable Search Engine ID (CSE).'**
  String get googleSearchSetup;

  /// No description provided for @searchEngineId.
  ///
  /// In en, this message translates to:
  /// **'Search Engine ID *'**
  String get searchEngineId;

  /// No description provided for @searchEngineIdHint.
  ///
  /// In en, this message translates to:
  /// **'a1b2c3d4e5f...'**
  String get searchEngineIdHint;

  /// No description provided for @maxResults.
  ///
  /// In en, this message translates to:
  /// **'Max Results'**
  String get maxResults;

  /// No description provided for @testSearchQuery.
  ///
  /// In en, this message translates to:
  /// **'Test Search Query'**
  String get testSearchQuery;

  /// No description provided for @testSearchQueryHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Flutter latest news'**
  String get testSearchQueryHint;

  /// No description provided for @testSearch.
  ///
  /// In en, this message translates to:
  /// **'Test Search'**
  String get testSearch;

  /// No description provided for @testSearchSuccess.
  ///
  /// In en, this message translates to:
  /// **'Search successful — {count} results from {provider}.'**
  String testSearchSuccess(int count, String provider);

  /// No description provided for @testSearchFailed.
  ///
  /// In en, this message translates to:
  /// **'Search test failed: {error}'**
  String testSearchFailed(String error);

  /// No description provided for @testDriveConnection.
  ///
  /// In en, this message translates to:
  /// **'Test Connection'**
  String get testDriveConnection;

  /// No description provided for @testDriveSuccess.
  ///
  /// In en, this message translates to:
  /// **'Connected — {count} items found in root folder.'**
  String testDriveSuccess(int count);

  /// No description provided for @testDriveFailed.
  ///
  /// In en, this message translates to:
  /// **'Drive test failed: {error}'**
  String testDriveFailed(String error);

  /// No description provided for @serverLoadingSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Loading settings...'**
  String get serverLoadingSettingsTitle;

  /// No description provided for @serverLoadingSettingsBody.
  ///
  /// In en, this message translates to:
  /// **'Server settings are being loaded into the app. Please wait.'**
  String get serverLoadingSettingsBody;

  /// No description provided for @serverSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Switch To Server Mode'**
  String get serverSwitchTitle;

  /// No description provided for @serverSwitchBody.
  ///
  /// In en, this message translates to:
  /// **'You are switching to server mode. Agents, schedules, and settings will use the remote server database. The local database stays separate and is not synchronized.'**
  String get serverSwitchBody;

  /// No description provided for @serverSwitchAction.
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get serverSwitchAction;

  /// No description provided for @serverConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected to server!'**
  String get serverConnected;

  /// No description provided for @serverConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed — check server URL and API key authorization.'**
  String get serverConnectionFailed;

  /// No description provided for @serverNotReachable.
  ///
  /// In en, this message translates to:
  /// **'Server not reachable.'**
  String get serverNotReachable;

  /// No description provided for @serverReachableAuthorized.
  ///
  /// In en, this message translates to:
  /// **'Server reachable and authorization is valid.'**
  String get serverReachableAuthorized;

  /// No description provided for @serverReachableUnauthorized.
  ///
  /// In en, this message translates to:
  /// **'Server reachable, but API key authorization failed.'**
  String get serverReachableUnauthorized;

  /// No description provided for @serverSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Server Mode Settings'**
  String get serverSettingsTitle;

  /// No description provided for @serverSettingsError.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String serverSettingsError(String error);

  /// No description provided for @serverSettingsUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get serverSettingsUrlLabel;

  /// No description provided for @serverSettingsUrlHint.
  ///
  /// In en, this message translates to:
  /// **'http://192.168.1.100:7771'**
  String get serverSettingsUrlHint;

  /// No description provided for @serverSettingsUrlHelper.
  ///
  /// In en, this message translates to:
  /// **'Include port; no trailing slash'**
  String get serverSettingsUrlHelper;

  /// No description provided for @serverSettingsUrlInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid URL'**
  String get serverSettingsUrlInvalid;

  /// No description provided for @serverTestConnectionButton.
  ///
  /// In en, this message translates to:
  /// **'Test Connection'**
  String get serverTestConnectionButton;

  /// No description provided for @serverConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get serverConnecting;

  /// No description provided for @serverConnectUseRemote.
  ///
  /// In en, this message translates to:
  /// **'Connect & Use Remote'**
  String get serverConnectUseRemote;

  /// No description provided for @serverAboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About Server Mode'**
  String get serverAboutTitle;

  /// No description provided for @serverAboutBody.
  ///
  /// In en, this message translates to:
  /// **'Server Mode connects this app to a TealKit Server instance running on your home server, NAS, or Raspberry Pi.\n\nTask data will be read from and written to the remote server. Schedule execution also happens on the server — the app does not need to be open.'**
  String get serverAboutBody;

  /// No description provided for @serverApiKeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Server API Key'**
  String get serverApiKeyTitle;

  /// No description provided for @serverApiKeyBody.
  ///
  /// In en, this message translates to:
  /// **'This app has auto-generated a unique API key. Configure your TealKit Server with it so only this app can connect.'**
  String get serverApiKeyBody;

  /// No description provided for @serverCopyFullKeyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Copy full key'**
  String get serverCopyFullKeyTooltip;

  /// No description provided for @serverApiKeyCopied.
  ///
  /// In en, this message translates to:
  /// **'API key copied to clipboard'**
  String get serverApiKeyCopied;

  /// No description provided for @serverApiKeyEnvHint.
  ///
  /// In en, this message translates to:
  /// **'Set this as an environment variable when starting the server:\ndocker run -e TEALKIT_API_KEY=<key> ...'**
  String get serverApiKeyEnvHint;

  /// No description provided for @emailNotification.
  ///
  /// In en, this message translates to:
  /// **'Email Notification'**
  String get emailNotification;

  /// No description provided for @sendEmailAfterTask.
  ///
  /// In en, this message translates to:
  /// **'Send email after task runs'**
  String get sendEmailAfterTask;

  /// No description provided for @toEmail.
  ///
  /// In en, this message translates to:
  /// **'To (email)'**
  String get toEmail;

  /// No description provided for @toEmailHint.
  ///
  /// In en, this message translates to:
  /// **'user@example.com'**
  String get toEmailHint;

  /// No description provided for @subject.
  ///
  /// In en, this message translates to:
  /// **'Subject'**
  String get subject;

  /// No description provided for @subjectHint.
  ///
  /// In en, this message translates to:
  /// **'Task Result: [task_name]'**
  String get subjectHint;

  /// No description provided for @sendCondition.
  ///
  /// In en, this message translates to:
  /// **'Send Condition'**
  String get sendCondition;

  /// No description provided for @always.
  ///
  /// In en, this message translates to:
  /// **'Always'**
  String get always;

  /// No description provided for @onSuccess.
  ///
  /// In en, this message translates to:
  /// **'On Success'**
  String get onSuccess;

  /// No description provided for @onFailure.
  ///
  /// In en, this message translates to:
  /// **'On Failure'**
  String get onFailure;

  /// No description provided for @onResultChange.
  ///
  /// In en, this message translates to:
  /// **'On Result Change'**
  String get onResultChange;

  /// No description provided for @outputType.
  ///
  /// In en, this message translates to:
  /// **'Output Type'**
  String get outputType;

  /// No description provided for @outputTypeEmail.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get outputTypeEmail;

  /// No description provided for @outputTypeFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get outputTypeFile;

  /// No description provided for @outputTypeSftp.
  ///
  /// In en, this message translates to:
  /// **'SFTP Upload'**
  String get outputTypeSftp;

  /// No description provided for @sftpUseConfiguredSshServer.
  ///
  /// In en, this message translates to:
  /// **'Use configured SSH server'**
  String get sftpUseConfiguredSshServer;

  /// No description provided for @sftpHost.
  ///
  /// In en, this message translates to:
  /// **'SFTP Host'**
  String get sftpHost;

  /// No description provided for @sftpPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get sftpPort;

  /// No description provided for @sftpUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get sftpUsername;

  /// No description provided for @sftpPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get sftpPassword;

  /// No description provided for @sftpRemotePath.
  ///
  /// In en, this message translates to:
  /// **'Default Folder (Remote Path)'**
  String get sftpRemotePath;

  /// No description provided for @sftpRemotePathHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. /uploads/tealkit'**
  String get sftpRemotePathHint;

  /// No description provided for @sftpNotifyByEmail.
  ///
  /// In en, this message translates to:
  /// **'Send notification e-mail after upload'**
  String get sftpNotifyByEmail;

  /// No description provided for @sftpNotifyEmailAddress.
  ///
  /// In en, this message translates to:
  /// **'Notification e-mail address'**
  String get sftpNotifyEmailAddress;

  /// No description provided for @sftpNotifyEmailSubject.
  ///
  /// In en, this message translates to:
  /// **'Subject'**
  String get sftpNotifyEmailSubject;

  /// No description provided for @sftpNotifyEmailBody.
  ///
  /// In en, this message translates to:
  /// **'Body (leave blank for default template)'**
  String get sftpNotifyEmailBody;

  /// No description provided for @sftpNotifyEmailBodyHint.
  ///
  /// In en, this message translates to:
  /// **'Leave blank for auto-generated text'**
  String get sftpNotifyEmailBodyHint;

  /// No description provided for @outputDirectory.
  ///
  /// In en, this message translates to:
  /// **'Output Directory'**
  String get outputDirectory;

  /// No description provided for @outputDirectoryHint.
  ///
  /// In en, this message translates to:
  /// **'Choose where generated files should be saved'**
  String get outputDirectoryHint;

  /// No description provided for @outputDirectoryNote.
  ///
  /// In en, this message translates to:
  /// **'Directory picker availability depends on platform permissions.'**
  String get outputDirectoryNote;

  /// No description provided for @outputFolderRequired.
  ///
  /// In en, this message translates to:
  /// **'An output folder must be selected when using File output type. Tap the folder icon to choose a directory.'**
  String get outputFolderRequired;

  /// No description provided for @chooseDirectory.
  ///
  /// In en, this message translates to:
  /// **'Choose Directory'**
  String get chooseDirectory;

  /// No description provided for @fileNamePattern.
  ///
  /// In en, this message translates to:
  /// **'File Name Pattern'**
  String get fileNamePattern;

  /// No description provided for @fileNamePatternHint.
  ///
  /// In en, this message translates to:
  /// **'task_result_{date}.txt'**
  String fileNamePatternHint(Object date);

  /// No description provided for @addExecutionLogToOutput.
  ///
  /// In en, this message translates to:
  /// **'Add execution log to output'**
  String get addExecutionLogToOutput;

  /// No description provided for @zipOutputFiles.
  ///
  /// In en, this message translates to:
  /// **'Zip output files'**
  String get zipOutputFiles;

  /// No description provided for @runningTaskWithDuckdb.
  ///
  /// In en, this message translates to:
  /// **'Running task and indexing/searching with DuckDB...'**
  String get runningTaskWithDuckdb;

  /// No description provided for @openLatestFile.
  ///
  /// In en, this message translates to:
  /// **'Open latest file'**
  String get openLatestFile;

  /// No description provided for @pathNotFound.
  ///
  /// In en, this message translates to:
  /// **'Path not found'**
  String get pathNotFound;

  /// No description provided for @openFailed.
  ///
  /// In en, this message translates to:
  /// **'Open failed: {error}'**
  String openFailed(String error);

  /// No description provided for @localSearchIndexDuckdb.
  ///
  /// In en, this message translates to:
  /// **'Local search index (DuckDB)'**
  String get localSearchIndexDuckdb;

  /// No description provided for @duckdbSizeLimitDescription.
  ///
  /// In en, this message translates to:
  /// **'Maximum indexed data size in GB. Indexing stops when the cap is reached.'**
  String get duckdbSizeLimitDescription;

  /// No description provided for @duckdbSizeLimitGb.
  ///
  /// In en, this message translates to:
  /// **'DuckDB size limit (GB)'**
  String get duckdbSizeLimitGb;

  /// No description provided for @duckdbSizeLimitHint.
  ///
  /// In en, this message translates to:
  /// **'1.0'**
  String get duckdbSizeLimitHint;

  /// No description provided for @pushNotification.
  ///
  /// In en, this message translates to:
  /// **'Push Notification'**
  String get pushNotification;

  /// No description provided for @sendPush.
  ///
  /// In en, this message translates to:
  /// **'Send push notification'**
  String get sendPush;

  /// No description provided for @title.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get title;

  /// No description provided for @titleHint.
  ///
  /// In en, this message translates to:
  /// **'Task completed'**
  String get titleHint;

  /// No description provided for @deviceToken.
  ///
  /// In en, this message translates to:
  /// **'Device Token'**
  String get deviceToken;

  /// No description provided for @noTasksYet.
  ///
  /// In en, this message translates to:
  /// **'No workflows yet'**
  String get noTasksYet;

  /// No description provided for @createScheduledTask.
  ///
  /// In en, this message translates to:
  /// **'Create a scheduled workflow for your AI assistant'**
  String get createScheduledTask;

  /// No description provided for @browseExamples.
  ///
  /// In en, this message translates to:
  /// **'Browse Examples'**
  String get browseExamples;

  /// No description provided for @browseExamplesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Pick a predefined example task'**
  String get browseExamplesTooltip;

  /// No description provided for @orStartFromExample.
  ///
  /// In en, this message translates to:
  /// **'or start from an example'**
  String get orStartFromExample;

  /// No description provided for @initialMessage.
  ///
  /// In en, this message translates to:
  /// **'Initial Message'**
  String get initialMessage;

  /// No description provided for @fieldRequired.
  ///
  /// In en, this message translates to:
  /// **'This field is required'**
  String get fieldRequired;

  /// No description provided for @invalidEmail.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email address'**
  String get invalidEmail;

  /// No description provided for @searchTasks.
  ///
  /// In en, this message translates to:
  /// **'Search workflows...'**
  String get searchTasks;

  /// No description provided for @noMatchingTasks.
  ///
  /// In en, this message translates to:
  /// **'No matching workflows found'**
  String get noMatchingTasks;

  /// No description provided for @lastRun.
  ///
  /// In en, this message translates to:
  /// **'Last: {date}'**
  String lastRun(String date);

  /// No description provided for @nextRun.
  ///
  /// In en, this message translates to:
  /// **'Next: {date}'**
  String nextRun(String date);

  /// No description provided for @never.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get never;

  /// No description provided for @columnActions.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get columnActions;

  /// No description provided for @columnName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get columnName;

  /// No description provided for @columnUpdated.
  ///
  /// In en, this message translates to:
  /// **'Updated'**
  String get columnUpdated;

  /// No description provided for @columnPrompt.
  ///
  /// In en, this message translates to:
  /// **'Prompt'**
  String get columnPrompt;

  /// No description provided for @columnSchedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get columnSchedule;

  /// No description provided for @columnStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get columnStatus;

  /// No description provided for @columnEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get columnEnabled;

  /// No description provided for @columnLastRun.
  ///
  /// In en, this message translates to:
  /// **'Last Run'**
  String get columnLastRun;

  /// No description provided for @costLastShort.
  ///
  /// In en, this message translates to:
  /// **'Last'**
  String get costLastShort;

  /// No description provided for @costTotalShort.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get costTotalShort;

  /// No description provided for @executeNow.
  ///
  /// In en, this message translates to:
  /// **'Execute now'**
  String get executeNow;

  /// No description provided for @taskRunSuccess.
  ///
  /// In en, this message translates to:
  /// **'Workflow executed successfully'**
  String get taskRunSuccess;

  /// No description provided for @taskRunFailed.
  ///
  /// In en, this message translates to:
  /// **'Workflow execution finished with errors'**
  String get taskRunFailed;

  /// No description provided for @taskRunError.
  ///
  /// In en, this message translates to:
  /// **'Workflow execution failed: {error}'**
  String taskRunError(String error);

  /// No description provided for @statusDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get statusDisabled;

  /// No description provided for @statusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get statusFailed;

  /// No description provided for @statusFailedCount.
  ///
  /// In en, this message translates to:
  /// **'Failed ({count} in a row)'**
  String statusFailedCount(int count);

  /// No description provided for @statusOk.
  ///
  /// In en, this message translates to:
  /// **'OK — {count} runs'**
  String statusOk(int count);

  /// No description provided for @statusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get statusPending;

  /// No description provided for @statusPendingNeverRun.
  ///
  /// In en, this message translates to:
  /// **'Pending — never run'**
  String get statusPendingNeverRun;

  /// No description provided for @detailGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get detailGeneral;

  /// No description provided for @detailName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get detailName;

  /// No description provided for @detailDescription.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get detailDescription;

  /// No description provided for @detailAgentId.
  ///
  /// In en, this message translates to:
  /// **'Agent ID'**
  String get detailAgentId;

  /// No description provided for @detailEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get detailEnabled;

  /// No description provided for @detailTags.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get detailTags;

  /// No description provided for @detailCreated.
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get detailCreated;

  /// No description provided for @detailUpdated.
  ///
  /// In en, this message translates to:
  /// **'Updated'**
  String get detailUpdated;

  /// No description provided for @detailPrompts.
  ///
  /// In en, this message translates to:
  /// **'Prompts'**
  String get detailPrompts;

  /// No description provided for @detailSystemPrompt.
  ///
  /// In en, this message translates to:
  /// **'System Prompt'**
  String get detailSystemPrompt;

  /// No description provided for @detailPrompt.
  ///
  /// In en, this message translates to:
  /// **'Prompt'**
  String get detailPrompt;

  /// No description provided for @detailSchedule.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get detailSchedule;

  /// No description provided for @detailCron.
  ///
  /// In en, this message translates to:
  /// **'Cron'**
  String get detailCron;

  /// No description provided for @detailHint.
  ///
  /// In en, this message translates to:
  /// **'Hint'**
  String get detailHint;

  /// No description provided for @detailMaxRetries.
  ///
  /// In en, this message translates to:
  /// **'Max Retries'**
  String get detailMaxRetries;

  /// No description provided for @detailRetryOnFailure.
  ///
  /// In en, this message translates to:
  /// **'Retry on Failure'**
  String get detailRetryOnFailure;

  /// No description provided for @detailRetryDelay.
  ///
  /// In en, this message translates to:
  /// **'Retry Delay'**
  String get detailRetryDelay;

  /// No description provided for @detailRetryDelayValue.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String detailRetryDelayValue(int minutes);

  /// No description provided for @detailExecuteImmediately.
  ///
  /// In en, this message translates to:
  /// **'Execute Immediately'**
  String get detailExecuteImmediately;

  /// No description provided for @detailLlmOverride.
  ///
  /// In en, this message translates to:
  /// **'LLM Override'**
  String get detailLlmOverride;

  /// No description provided for @detailProvider.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get detailProvider;

  /// No description provided for @detailModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get detailModel;

  /// No description provided for @detailBaseUrl.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get detailBaseUrl;

  /// No description provided for @detailTemperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get detailTemperature;

  /// No description provided for @detailMaxTokens.
  ///
  /// In en, this message translates to:
  /// **'Max Tokens'**
  String get detailMaxTokens;

  /// No description provided for @detailApiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get detailApiKey;

  /// No description provided for @detailBuiltInTools.
  ///
  /// In en, this message translates to:
  /// **'Built-in Tools ({count})'**
  String detailBuiltInTools(int count);

  /// No description provided for @detailMcpTools.
  ///
  /// In en, this message translates to:
  /// **'MCP Tools ({count})'**
  String detailMcpTools(int count);

  /// No description provided for @detailProviders.
  ///
  /// In en, this message translates to:
  /// **'Providers'**
  String get detailProviders;

  /// No description provided for @detailEmail.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get detailEmail;

  /// No description provided for @detailWebSearch.
  ///
  /// In en, this message translates to:
  /// **'Web Search'**
  String get detailWebSearch;

  /// No description provided for @detailNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get detailNotifications;

  /// No description provided for @detailEmailTo.
  ///
  /// In en, this message translates to:
  /// **'Email To'**
  String get detailEmailTo;

  /// No description provided for @detailSubject.
  ///
  /// In en, this message translates to:
  /// **'Subject'**
  String get detailSubject;

  /// No description provided for @detailSendWhen.
  ///
  /// In en, this message translates to:
  /// **'Send When'**
  String get detailSendWhen;

  /// No description provided for @detailPush.
  ///
  /// In en, this message translates to:
  /// **'Push'**
  String get detailPush;

  /// No description provided for @detailPushTitle.
  ///
  /// In en, this message translates to:
  /// **'Push Title'**
  String get detailPushTitle;

  /// No description provided for @detailDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get detailDownload;

  /// No description provided for @detailDefaultDownloads.
  ///
  /// In en, this message translates to:
  /// **'Default downloads'**
  String get detailDefaultDownloads;

  /// No description provided for @detailUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get detailUpload;

  /// No description provided for @detailTotalRuns.
  ///
  /// In en, this message translates to:
  /// **'Total Runs'**
  String get detailTotalRuns;

  /// No description provided for @detailConsecutiveFailures.
  ///
  /// In en, this message translates to:
  /// **'Consecutive Failures'**
  String get detailConsecutiveFailures;

  /// No description provided for @detailLastRun.
  ///
  /// In en, this message translates to:
  /// **'Last Run'**
  String get detailLastRun;

  /// No description provided for @detailNextRun.
  ///
  /// In en, this message translates to:
  /// **'Next Run'**
  String get detailNextRun;

  /// No description provided for @detailLastResult.
  ///
  /// In en, this message translates to:
  /// **'Last Result'**
  String get detailLastResult;

  /// No description provided for @detailLastError.
  ///
  /// In en, this message translates to:
  /// **'Last Error'**
  String get detailLastError;

  /// No description provided for @userLog.
  ///
  /// In en, this message translates to:
  /// **'User Log'**
  String get userLog;

  /// No description provided for @executionLog.
  ///
  /// In en, this message translates to:
  /// **'Execution Log'**
  String get executionLog;

  /// No description provided for @generatedFiles.
  ///
  /// In en, this message translates to:
  /// **'Generated Files'**
  String get generatedFiles;

  /// No description provided for @detailRunHistory.
  ///
  /// In en, this message translates to:
  /// **'Run History ({count})'**
  String detailRunHistory(int count);

  /// No description provided for @detailDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration: {ms}ms'**
  String detailDuration(int ms);

  /// No description provided for @detailDurationNA.
  ///
  /// In en, this message translates to:
  /// **'Duration: N/A'**
  String get detailDurationNA;

  /// No description provided for @unknownError.
  ///
  /// In en, this message translates to:
  /// **'Unknown error'**
  String get unknownError;

  /// No description provided for @viewResult.
  ///
  /// In en, this message translates to:
  /// **'View result'**
  String get viewResult;

  /// No description provided for @runDate.
  ///
  /// In en, this message translates to:
  /// **'Run {date}'**
  String runDate(String date);

  /// No description provided for @result.
  ///
  /// In en, this message translates to:
  /// **'Result:'**
  String get result;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error:'**
  String get error;

  /// No description provided for @configured.
  ///
  /// In en, this message translates to:
  /// **'configured'**
  String get configured;

  /// No description provided for @allTools.
  ///
  /// In en, this message translates to:
  /// **'all'**
  String get allTools;

  /// No description provided for @webSearchMaxResults.
  ///
  /// In en, this message translates to:
  /// **'max {count}'**
  String webSearchMaxResults(int count);

  /// No description provided for @weatherSystemPrompt.
  ///
  /// In en, this message translates to:
  /// **'You are a weather assistant. Use the weather tools to answer questions about current conditions, hourly and daily forecasts. Always include temperature, wind speed, and precipitation probability. When the user mentions a city, geocode it first, then fetch weather data. Present results concisely with units (°C, km/h, %). If no location is specified, use the configured default.'**
  String get weatherSystemPrompt;

  /// No description provided for @weatherDisplayName.
  ///
  /// In en, this message translates to:
  /// **'Weather'**
  String get weatherDisplayName;

  /// No description provided for @weatherDescription.
  ///
  /// In en, this message translates to:
  /// **'Fetch weather forecasts using Open-Meteo (free, no API key). Provides current conditions, hourly and daily forecasts.'**
  String get weatherDescription;

  /// No description provided for @documentDisplayName.
  ///
  /// In en, this message translates to:
  /// **'Document Search'**
  String get documentDisplayName;

  /// No description provided for @documentDescription.
  ///
  /// In en, this message translates to:
  /// **'Search and index local documents (TXT, MD, DOCX, XLSX, PDF, CSV). Extracts text content and provides full-text search via DuckDB.'**
  String get documentDescription;

  /// No description provided for @documentSystemPrompt.
  ///
  /// In en, this message translates to:
  /// **'You are a document search assistant. Use the document tools to find and search through local documents. When the user asks about document content, use search_documents to find relevant files, then get_document_content to read specific documents. Present results clearly with file names and relevant excerpts. If no matches found, suggest broadening the search terms.'**
  String get documentSystemPrompt;

  /// No description provided for @reindexDocuments.
  ///
  /// In en, this message translates to:
  /// **'Reindex Documents'**
  String get reindexDocuments;

  /// No description provided for @reindexDocumentsHint.
  ///
  /// In en, this message translates to:
  /// **'Re-scan the folder and rebuild the search index.'**
  String get reindexDocumentsHint;

  /// No description provided for @reindexing.
  ///
  /// In en, this message translates to:
  /// **'Indexing documents…'**
  String get reindexing;

  /// No description provided for @reindexComplete.
  ///
  /// In en, this message translates to:
  /// **'Indexing complete: {count} documents in {ms}ms (files: {fileSizeKb} KB, index: {indexSizeKb} KB)'**
  String reindexComplete(
    int count,
    int ms,
    String fileSizeKb,
    String indexSizeKb,
  );

  /// No description provided for @reindexFailed.
  ///
  /// In en, this message translates to:
  /// **'Indexing failed: {error}'**
  String reindexFailed(String error);

  /// No description provided for @indexingStart.
  ///
  /// In en, this message translates to:
  /// **'Start Indexing'**
  String get indexingStart;

  /// No description provided for @indexingStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get indexingStop;

  /// No description provided for @indexingProgress.
  ///
  /// In en, this message translates to:
  /// **'Indexing: {current}/{total}'**
  String indexingProgress(int current, int total);

  /// No description provided for @indexingCurrentFile.
  ///
  /// In en, this message translates to:
  /// **'Current: {fileName}'**
  String indexingCurrentFile(String fileName);

  /// No description provided for @indexingCancelled.
  ///
  /// In en, this message translates to:
  /// **'Indexing cancelled after {count} documents'**
  String indexingCancelled(int count);

  /// No description provided for @indexingStrategyNow.
  ///
  /// In en, this message translates to:
  /// **'Index now (at initialization)'**
  String get indexingStrategyNow;

  /// No description provided for @indexingStrategyLazy.
  ///
  /// In en, this message translates to:
  /// **'Index before first search'**
  String get indexingStrategyLazy;

  /// No description provided for @indexEachTime.
  ///
  /// In en, this message translates to:
  /// **'Index each time running the agent'**
  String get indexEachTime;

  /// No description provided for @indexFirstTime.
  ///
  /// In en, this message translates to:
  /// **'Index first time'**
  String get indexFirstTime;

  /// No description provided for @paramLabelRootPath.
  ///
  /// In en, this message translates to:
  /// **'Root Path'**
  String get paramLabelRootPath;

  /// No description provided for @paramLabelFileTypes.
  ///
  /// In en, this message translates to:
  /// **'File Types'**
  String get paramLabelFileTypes;

  /// No description provided for @paramLabelIndexingStrategy.
  ///
  /// In en, this message translates to:
  /// **'Indexing Strategy'**
  String get paramLabelIndexingStrategy;

  /// No description provided for @paramLabelMaxDocuments.
  ///
  /// In en, this message translates to:
  /// **'Max Documents'**
  String get paramLabelMaxDocuments;

  /// No description provided for @paramLabelWebsiteUrls.
  ///
  /// In en, this message translates to:
  /// **'Website URLs'**
  String get paramLabelWebsiteUrls;

  /// No description provided for @paramLabelMaxPages.
  ///
  /// In en, this message translates to:
  /// **'Max Pages'**
  String get paramLabelMaxPages;

  /// No description provided for @paramLabelMaxResults.
  ///
  /// In en, this message translates to:
  /// **'Max Results'**
  String get paramLabelMaxResults;

  /// No description provided for @paramLabelAccessToken.
  ///
  /// In en, this message translates to:
  /// **'Access Token'**
  String get paramLabelAccessToken;

  /// No description provided for @paramLabelUserId.
  ///
  /// In en, this message translates to:
  /// **'User ID'**
  String get paramLabelUserId;

  /// No description provided for @enumAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get enumAuto;

  /// No description provided for @llmSettings.
  ///
  /// In en, this message translates to:
  /// **'LLM Settings'**
  String get llmSettings;

  /// No description provided for @llmSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Configure your AI provider & model'**
  String get llmSettingsSubtitle;

  /// No description provided for @llmSettingsInfo.
  ///
  /// In en, this message translates to:
  /// **'Configure your default LLM provider here. These settings are stored securely on your device and can be applied automatically when creating new tasks.'**
  String get llmSettingsInfo;

  /// No description provided for @llmSettingsSaved.
  ///
  /// In en, this message translates to:
  /// **'LLM settings saved'**
  String get llmSettingsSaved;

  /// No description provided for @llmSettingsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to save LLM settings: {error}'**
  String llmSettingsSaveFailed(String error);

  /// No description provided for @llmSettingsCleared.
  ///
  /// In en, this message translates to:
  /// **'LLM settings cleared'**
  String get llmSettingsCleared;

  /// No description provided for @llmClearSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear LLM Settings'**
  String get llmClearSettingsTitle;

  /// No description provided for @llmClearSettingsMessage.
  ///
  /// In en, this message translates to:
  /// **'This will remove all stored LLM credentials and configuration. Are you sure?'**
  String get llmClearSettingsMessage;

  /// No description provided for @llmProviderLabel.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get llmProviderLabel;

  /// No description provided for @llmModelLabel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get llmModelLabel;

  /// No description provided for @llmModelHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. gemini-2.5-flash'**
  String get llmModelHint;

  /// No description provided for @llmModelRequired.
  ///
  /// In en, this message translates to:
  /// **'Model name is required'**
  String get llmModelRequired;

  /// No description provided for @llmApiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get llmApiKeyLabel;

  /// No description provided for @llmApiKeyRequired.
  ///
  /// In en, this message translates to:
  /// **'API key is required for this provider'**
  String get llmApiKeyRequired;

  /// No description provided for @llmApiKeyOptional.
  ///
  /// In en, this message translates to:
  /// **'API key (optional)'**
  String get llmApiKeyOptional;

  /// No description provided for @llmBaseUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get llmBaseUrlLabel;

  /// No description provided for @llmBaseUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'Base URL is required for this provider'**
  String get llmBaseUrlRequired;

  /// No description provided for @llmUseNativeToolCall.
  ///
  /// In en, this message translates to:
  /// **'Use native tool calling'**
  String get llmUseNativeToolCall;

  /// No description provided for @llmUseNativeToolCallDescription.
  ///
  /// In en, this message translates to:
  /// **'Use Ollama native tool calling capabilities instead of text-based tools.'**
  String get llmUseNativeToolCallDescription;

  /// No description provided for @llmUseSafeToolCall.
  ///
  /// In en, this message translates to:
  /// **'Safe tool call mode'**
  String get llmUseSafeToolCall;

  /// No description provided for @llmUseSafeToolCallDescription.
  ///
  /// In en, this message translates to:
  /// **'Use grammar-constrained decoding to prevent malformed tool calls. Works even for models without native tool calling.'**
  String get llmUseSafeToolCallDescription;

  /// No description provided for @llmAdvancedSettings.
  ///
  /// In en, this message translates to:
  /// **'Advanced Settings'**
  String get llmAdvancedSettings;

  /// No description provided for @llmTemperatureRange.
  ///
  /// In en, this message translates to:
  /// **'Must be between 0.0 and 2.0'**
  String get llmTemperatureRange;

  /// No description provided for @llmMaxTokensRange.
  ///
  /// In en, this message translates to:
  /// **'Must be a positive number'**
  String get llmMaxTokensRange;

  /// No description provided for @llmConfiguredStatus.
  ///
  /// In en, this message translates to:
  /// **'Configured: {provider} / {model}'**
  String llmConfiguredStatus(String provider, String model);

  /// No description provided for @llmNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get llmNotConfigured;

  /// No description provided for @llmApplyDefaults.
  ///
  /// In en, this message translates to:
  /// **'Apply default LLM settings'**
  String get llmApplyDefaults;

  /// No description provided for @llmApplyDefaultsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Fill the fields below from your saved LLM settings'**
  String get llmApplyDefaultsSubtitle;

  /// No description provided for @llmDefaultsApplied.
  ///
  /// In en, this message translates to:
  /// **'Default LLM settings applied'**
  String get llmDefaultsApplied;

  /// No description provided for @llmNoDefaults.
  ///
  /// In en, this message translates to:
  /// **'No default LLM settings configured. Open LLM Settings from the home screen first.'**
  String get llmNoDefaults;

  /// No description provided for @llmAdvancedParams.
  ///
  /// In en, this message translates to:
  /// **'Advanced Parameters'**
  String get llmAdvancedParams;

  /// No description provided for @topK.
  ///
  /// In en, this message translates to:
  /// **'Top K'**
  String get topK;

  /// No description provided for @topKTooltip.
  ///
  /// In en, this message translates to:
  /// **'Limits vocabulary to the top-K tokens at each step. Lower = more deterministic. Range: 1–100.'**
  String get topKTooltip;

  /// No description provided for @topP.
  ///
  /// In en, this message translates to:
  /// **'Top P'**
  String get topP;

  /// No description provided for @topPTooltip.
  ///
  /// In en, this message translates to:
  /// **'Nucleus sampling cutoff. Lower = more focused output. Range: 0.0–1.0.'**
  String get topPTooltip;

  /// No description provided for @repeatPenalty.
  ///
  /// In en, this message translates to:
  /// **'Repeat Penalty'**
  String get repeatPenalty;

  /// No description provided for @repeatPenaltyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Penalizes repeating tokens. Values > 1.0 reduce repetition. Range: 0.5–2.0.'**
  String get repeatPenaltyTooltip;

  /// No description provided for @seed.
  ///
  /// In en, this message translates to:
  /// **'Seed'**
  String get seed;

  /// No description provided for @seedTooltip.
  ///
  /// In en, this message translates to:
  /// **'Random seed for reproducible outputs. Leave empty for random.'**
  String get seedTooltip;

  /// No description provided for @llm2EditableSettings.
  ///
  /// In en, this message translates to:
  /// **'LLM 2 settings (editable for this task)'**
  String get llm2EditableSettings;

  /// No description provided for @llm2SettingsOverrideHint.
  ///
  /// In en, this message translates to:
  /// **'Pre-filled from your LLM 2 global settings. Changes apply only to this task.'**
  String get llm2SettingsOverrideHint;

  /// No description provided for @interactiveMode.
  ///
  /// In en, this message translates to:
  /// **'Interactive'**
  String get interactiveMode;

  /// No description provided for @interactiveModeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Test this task interactively'**
  String get interactiveModeTooltip;

  /// No description provided for @interactiveModeTitle.
  ///
  /// In en, this message translates to:
  /// **'Interactive Mode'**
  String get interactiveModeTitle;

  /// No description provided for @interactiveNoLlm.
  ///
  /// In en, this message translates to:
  /// **'No LLM configured. Please configure LLM settings first.'**
  String get interactiveNoLlm;

  /// No description provided for @interactiveConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to MCP servers…'**
  String get interactiveConnecting;

  /// No description provided for @interactiveReady.
  ///
  /// In en, this message translates to:
  /// **'Ready — type a message to test this task'**
  String get interactiveReady;

  /// No description provided for @interactiveSystemPromptLocked.
  ///
  /// In en, this message translates to:
  /// **'System prompt locked from task config'**
  String get interactiveSystemPromptLocked;

  /// No description provided for @interactiveToolsAvailable.
  ///
  /// In en, this message translates to:
  /// **'{count} tools available'**
  String interactiveToolsAvailable(int count);

  /// No description provided for @interactiveNoTools.
  ///
  /// In en, this message translates to:
  /// **'No tools configured'**
  String get interactiveNoTools;

  /// No description provided for @interactiveDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect & Close'**
  String get interactiveDisconnect;

  /// No description provided for @sectionRawOutput.
  ///
  /// In en, this message translates to:
  /// **'Raw Output'**
  String get sectionRawOutput;

  /// No description provided for @sectionOutputUser.
  ///
  /// In en, this message translates to:
  /// **'Output User'**
  String get sectionOutputUser;

  /// No description provided for @sectionOutputFiles.
  ///
  /// In en, this message translates to:
  /// **'Output Files'**
  String get sectionOutputFiles;

  /// No description provided for @sectionSchedulerLog.
  ///
  /// In en, this message translates to:
  /// **'Scheduler Log'**
  String get sectionSchedulerLog;

  /// No description provided for @noRawOutput.
  ///
  /// In en, this message translates to:
  /// **'No raw output recorded for last run'**
  String get noRawOutput;

  /// No description provided for @noOutputUser.
  ///
  /// In en, this message translates to:
  /// **'No user output recorded'**
  String get noOutputUser;

  /// No description provided for @noOutputFiles.
  ///
  /// In en, this message translates to:
  /// **'No output files found'**
  String get noOutputFiles;

  /// No description provided for @noSchedulerLog.
  ///
  /// In en, this message translates to:
  /// **'No scheduler events recorded'**
  String get noSchedulerLog;

  /// No description provided for @schedulerEventScheduled.
  ///
  /// In en, this message translates to:
  /// **'Scheduled'**
  String get schedulerEventScheduled;

  /// No description provided for @schedulerEventFired.
  ///
  /// In en, this message translates to:
  /// **'Fired'**
  String get schedulerEventFired;

  /// No description provided for @schedulerEventStarted.
  ///
  /// In en, this message translates to:
  /// **'Started'**
  String get schedulerEventStarted;

  /// No description provided for @schedulerEventCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get schedulerEventCompleted;

  /// No description provided for @schedulerEventFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get schedulerEventFailed;

  /// No description provided for @schedulerEventSkipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get schedulerEventSkipped;

  /// No description provided for @schedulerEventAlarm.
  ///
  /// In en, this message translates to:
  /// **'Alarm'**
  String get schedulerEventAlarm;

  /// No description provided for @schedulerActivity.
  ///
  /// In en, this message translates to:
  /// **'Background Activity'**
  String get schedulerActivity;

  /// No description provided for @schedulerActivityTitle.
  ///
  /// In en, this message translates to:
  /// **'Background Activity · Last 48 h'**
  String get schedulerActivityTitle;

  /// No description provided for @outputFileRunDir.
  ///
  /// In en, this message translates to:
  /// **'Run {date}'**
  String outputFileRunDir(String date);

  /// No description provided for @daysToLive.
  ///
  /// In en, this message translates to:
  /// **'Days to keep output files'**
  String get daysToLive;

  /// No description provided for @copyToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy to clipboard'**
  String get copyToClipboard;

  /// No description provided for @copiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copiedToClipboard;

  /// No description provided for @schedulerLogDetail.
  ///
  /// In en, this message translates to:
  /// **'Detail: {detail}'**
  String schedulerLogDetail(String detail);

  /// No description provided for @tabChaining.
  ///
  /// In en, this message translates to:
  /// **'Chaining'**
  String get tabChaining;

  /// No description provided for @chainThisTaskSection.
  ///
  /// In en, this message translates to:
  /// **'This Task'**
  String get chainThisTaskSection;

  /// No description provided for @chainIsSubtask.
  ///
  /// In en, this message translates to:
  /// **'Following agent mode'**
  String get chainIsSubtask;

  /// No description provided for @chainIsSubtaskHint.
  ///
  /// In en, this message translates to:
  /// **'Only run when triggered by another agent — scheduler is ignored'**
  String get chainIsSubtaskHint;

  /// No description provided for @chainSubtaskHint.
  ///
  /// In en, this message translates to:
  /// **'Tip: prefix the target agent\'s prompt with the placeholder [task_result] to inject the triggering agent\'s output.'**
  String get chainSubtaskHint;

  /// No description provided for @chainTriggerSection.
  ///
  /// In en, this message translates to:
  /// **'Trigger Follow-up Agent'**
  String get chainTriggerSection;

  /// No description provided for @chainTriggerSectionHint.
  ///
  /// In en, this message translates to:
  /// **'After this agent completes, optionally run another agent based on an LLM-evaluated condition.'**
  String get chainTriggerSectionHint;

  /// No description provided for @chainWithCondition.
  ///
  /// In en, this message translates to:
  /// **'With condition'**
  String get chainWithCondition;

  /// No description provided for @chainWithConditionHint.
  ///
  /// In en, this message translates to:
  /// **'Evaluate an LLM condition to pick between two follow-up agents.'**
  String get chainWithConditionHint;

  /// No description provided for @chainDirectFollowup.
  ///
  /// In en, this message translates to:
  /// **'Following agent (no condition)'**
  String get chainDirectFollowup;

  /// No description provided for @chainDirectFollowupHint.
  ///
  /// In en, this message translates to:
  /// **'Always trigger this agent after completion, passing [task_result].'**
  String get chainDirectFollowupHint;

  /// No description provided for @stopAfterToolCall.
  ///
  /// In en, this message translates to:
  /// **'Stop after tool call'**
  String get stopAfterToolCall;

  /// No description provided for @stopAfterToolCallHint.
  ///
  /// In en, this message translates to:
  /// **'Execute the tool call but don\'t send the result back to the LLM. The tool output becomes [task_result] for the following agent. With multiple steps: each step stops after its first tool call and the next step starts immediately.'**
  String get stopAfterToolCallHint;

  /// No description provided for @chainCondition.
  ///
  /// In en, this message translates to:
  /// **'Condition (LLM evaluated)'**
  String get chainCondition;

  /// No description provided for @chainConditionHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. temperature is below 10 degrees'**
  String get chainConditionHint;

  /// No description provided for @chainConditionHelper.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to always run the on-match task. In the target task\'s prompt, write [task_result] to inject this task\'s output.'**
  String get chainConditionHelper;

  /// No description provided for @chainOnMatch.
  ///
  /// In en, this message translates to:
  /// **'If condition matches — run agent'**
  String get chainOnMatch;

  /// No description provided for @chainOnNoMatch.
  ///
  /// In en, this message translates to:
  /// **'If condition does NOT match — run agent (else)'**
  String get chainOnNoMatch;

  /// No description provided for @chainTaskIdHint.
  ///
  /// In en, this message translates to:
  /// **'Agent ID...'**
  String get chainTaskIdHint;

  /// No description provided for @chainPickTask.
  ///
  /// In en, this message translates to:
  /// **'Pick Following Agent'**
  String get chainPickTask;

  /// No description provided for @chainTaskResultHint.
  ///
  /// In en, this message translates to:
  /// **'In any chained agent\'s prompt, write [task_result] to inject this agent\'s output.'**
  String get chainTaskResultHint;

  /// No description provided for @noTasksAvailable.
  ///
  /// In en, this message translates to:
  /// **'No agents available'**
  String get noTasksAvailable;

  /// No description provided for @noSubtasksAvailable.
  ///
  /// In en, this message translates to:
  /// **'No following agents found. Enable \'Following agent mode\' on an agent first.'**
  String get noSubtasksAvailable;

  /// No description provided for @scheduleDisabledSubtask.
  ///
  /// In en, this message translates to:
  /// **'Schedule inactive — this agent runs as a following agent and is triggered by another agent.'**
  String get scheduleDisabledSubtask;

  /// No description provided for @detailChainConfig.
  ///
  /// In en, this message translates to:
  /// **'Agent Chaining'**
  String get detailChainConfig;

  /// No description provided for @detailChainIsSubtask.
  ///
  /// In en, this message translates to:
  /// **'Following agent mode'**
  String get detailChainIsSubtask;

  /// No description provided for @detailChainCondition.
  ///
  /// In en, this message translates to:
  /// **'Condition'**
  String get detailChainCondition;

  /// No description provided for @detailChainOnMatch.
  ///
  /// In en, this message translates to:
  /// **'On match → task'**
  String get detailChainOnMatch;

  /// No description provided for @detailChainOnNoMatch.
  ///
  /// In en, this message translates to:
  /// **'On no match → task'**
  String get detailChainOnNoMatch;

  /// No description provided for @wizardLlmDescription.
  ///
  /// In en, this message translates to:
  /// **'Set provider, model, and API key. This is required before running tasks.'**
  String get wizardLlmDescription;

  /// No description provided for @wizardOpenLlmSettings.
  ///
  /// In en, this message translates to:
  /// **'Open LLM Settings'**
  String get wizardOpenLlmSettings;

  /// No description provided for @wizardDataSourcesDescription.
  ///
  /// In en, this message translates to:
  /// **'Set up Gmail, IMAP, web search, and cloud storage credentials.'**
  String get wizardDataSourcesDescription;

  /// No description provided for @wizardOpenDataSources.
  ///
  /// In en, this message translates to:
  /// **'Open Data Sources'**
  String get wizardOpenDataSources;

  /// No description provided for @wizardExternalToolsTitle.
  ///
  /// In en, this message translates to:
  /// **'Remote MCP Servers'**
  String get wizardExternalToolsTitle;

  /// No description provided for @wizardExternalToolsDescription.
  ///
  /// In en, this message translates to:
  /// **'Configure remote MCP servers accessible via HTTPS/SSE for use in your tasks.'**
  String get wizardExternalToolsDescription;

  /// No description provided for @wizardOpenExternalTools.
  ///
  /// In en, this message translates to:
  /// **'Open Remote Servers'**
  String get wizardOpenExternalTools;

  /// No description provided for @requiredLabel.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get requiredLabel;

  /// No description provided for @generalSection.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get generalSection;

  /// No description provided for @generalSectionDescription.
  ///
  /// In en, this message translates to:
  /// **'Theme, language, and backup settings.'**
  String get generalSectionDescription;

  /// No description provided for @themeLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get themeLabel;

  /// No description provided for @themeToggleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Cycle: Dark → System → Light'**
  String get themeToggleTooltip;

  /// No description provided for @languageLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageLabel;

  /// No description provided for @languageToggleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Toggle language'**
  String get languageToggleTooltip;

  /// No description provided for @defaultOutputDir.
  ///
  /// In en, this message translates to:
  /// **'Default Output Directory'**
  String get defaultOutputDir;

  /// No description provided for @defaultOutputDirDescription.
  ///
  /// In en, this message translates to:
  /// **'Folder where task results, output logs and execution logs are always saved.'**
  String get defaultOutputDirDescription;

  /// No description provided for @defaultOutputDirNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set — using app documents folder'**
  String get defaultOutputDirNotSet;

  /// No description provided for @outputRetentionDays.
  ///
  /// In en, this message translates to:
  /// **'Keep files for (days)'**
  String get outputRetentionDays;

  /// No description provided for @outputRetentionDaysDescription.
  ///
  /// In en, this message translates to:
  /// **'Output folders older than this are automatically deleted.'**
  String get outputRetentionDaysDescription;

  /// No description provided for @backgroundCheckInterval.
  ///
  /// In en, this message translates to:
  /// **'Background check interval'**
  String get backgroundCheckInterval;

  /// No description provided for @backgroundCheckIntervalDescription.
  ///
  /// In en, this message translates to:
  /// **'How often the app wakes up in the background to check for scheduled tasks. A shorter interval is more responsive but uses slightly more battery.'**
  String get backgroundCheckIntervalDescription;

  /// No description provided for @exportBackup.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get exportBackup;

  /// No description provided for @exportBackupDescription.
  ///
  /// In en, this message translates to:
  /// **'Tasks & MCP server definitions (no API keys)'**
  String get exportBackupDescription;

  /// No description provided for @importBackup.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importBackup;

  /// No description provided for @importBackupDescription.
  ///
  /// In en, this message translates to:
  /// **'Restore tasks & MCP servers from a JSON file'**
  String get importBackupDescription;

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String exportFailed(String error);

  /// No description provided for @exportSavedToDownloads.
  ///
  /// In en, this message translates to:
  /// **'Saved to Downloads: {fileName}'**
  String exportSavedToDownloads(String fileName);

  /// No description provided for @exportSuccess.
  ///
  /// In en, this message translates to:
  /// **'Backup exported successfully'**
  String get exportSuccess;

  /// No description provided for @phaseConfiguringLlm.
  ///
  /// In en, this message translates to:
  /// **'Configuring LLM…'**
  String get phaseConfiguringLlm;

  /// No description provided for @phaseConnectingExternalMcp.
  ///
  /// In en, this message translates to:
  /// **'Connecting external MCP servers…'**
  String get phaseConnectingExternalMcp;

  /// No description provided for @phaseConnectingInternalMcp.
  ///
  /// In en, this message translates to:
  /// **'Initializing built-in tools…'**
  String get phaseConnectingInternalMcp;

  /// No description provided for @chatSessionReset.
  ///
  /// In en, this message translates to:
  /// **'Chat session reset and reinitialized'**
  String get chatSessionReset;

  /// No description provided for @filterToolsHint.
  ///
  /// In en, this message translates to:
  /// **'Filter tools…'**
  String get filterToolsHint;

  /// No description provided for @noActiveTask.
  ///
  /// In en, this message translates to:
  /// **'No active task. Please select a task first.'**
  String get noActiveTask;

  /// No description provided for @resetChatSessionTooltip.
  ///
  /// In en, this message translates to:
  /// **'Reset chat session'**
  String get resetChatSessionTooltip;

  /// No description provided for @chatStartHint.
  ///
  /// In en, this message translates to:
  /// **'Send a message to start…'**
  String get chatStartHint;

  /// No description provided for @externalToolsScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Remote MCP Servers'**
  String get externalToolsScreenTitle;

  /// No description provided for @searchMcpCatalogTooltip.
  ///
  /// In en, this message translates to:
  /// **'Search MCP servers'**
  String get searchMcpCatalogTooltip;

  /// No description provided for @catalogUrlSaved.
  ///
  /// In en, this message translates to:
  /// **'Catalog URL saved'**
  String get catalogUrlSaved;

  /// No description provided for @failedToSaveUrl.
  ///
  /// In en, this message translates to:
  /// **'Failed to save URL: {error}'**
  String failedToSaveUrl(String error);

  /// No description provided for @testingServerMsg.
  ///
  /// In en, this message translates to:
  /// **'Testing {name}…'**
  String testingServerMsg(String name);

  /// No description provided for @mcpTestSuccessMsg.
  ///
  /// In en, this message translates to:
  /// **'MCP server test successful. {detail}'**
  String mcpTestSuccessMsg(String detail);

  /// No description provided for @mcpTestFailedMsg.
  ///
  /// In en, this message translates to:
  /// **'MCP test failed: {error}'**
  String mcpTestFailedMsg(String error);

  /// No description provided for @serverUrlRequiredForTest.
  ///
  /// In en, this message translates to:
  /// **'Server URL is required for test.'**
  String get serverUrlRequiredForTest;

  /// No description provided for @customServerAdded.
  ///
  /// In en, this message translates to:
  /// **'Custom MCP server added'**
  String get customServerAdded;

  /// No description provided for @failedToAddCustomServer.
  ///
  /// In en, this message translates to:
  /// **'Failed to add custom server: {error}'**
  String failedToAddCustomServer(String error);

  /// No description provided for @externalToolsGlobalInfo.
  ///
  /// In en, this message translates to:
  /// **'Configure remote MCP servers accessible over HTTPS/SSE. Add any server that exposes an MCP endpoint — no local installation needed.'**
  String get externalToolsGlobalInfo;

  /// No description provided for @catalogUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Catalog URL'**
  String get catalogUrlLabel;

  /// No description provided for @saveUrlButton.
  ///
  /// In en, this message translates to:
  /// **'Save URL'**
  String get saveUrlButton;

  /// No description provided for @smitheryApiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'Smithery API Key'**
  String get smitheryApiKeyLabel;

  /// No description provided for @smitheryApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Get yours at smithery.ai/account/api-keys'**
  String get smitheryApiKeyHint;

  /// No description provided for @smitheryApiKeyHelper.
  ///
  /// In en, this message translates to:
  /// **'Applied automatically to every server.smithery.ai endpoint that has no per-server key.'**
  String get smitheryApiKeyHelper;

  /// No description provided for @smitheryApiKeySaved.
  ///
  /// In en, this message translates to:
  /// **'Smithery API key saved'**
  String get smitheryApiKeySaved;

  /// No description provided for @saveSmitheryKeyButton.
  ///
  /// In en, this message translates to:
  /// **'Save Smithery Key'**
  String get saveSmitheryKeyButton;

  /// No description provided for @addCustomMcpServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Add custom MCP server'**
  String get addCustomMcpServerTitle;

  /// No description provided for @mcpApiKeyBearerHint.
  ///
  /// In en, this message translates to:
  /// **'Used as Bearer token'**
  String get mcpApiKeyBearerHint;

  /// No description provided for @mcpApiKeyOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'API Key (optional)'**
  String get mcpApiKeyOptionalLabel;

  /// No description provided for @apiPasswordOptionalLabel.
  ///
  /// In en, this message translates to:
  /// **'API Password (optional)'**
  String get apiPasswordOptionalLabel;

  /// No description provided for @mcpApiKeyBearerHelper.
  ///
  /// In en, this message translates to:
  /// **'For Smithery.ai servers: use your Smithery API key (smithery.ai → Settings → API Keys). It is sent as Authorization: Bearer with every request.'**
  String get mcpApiKeyBearerHelper;

  /// No description provided for @mcpApiPasswordOptionalHint.
  ///
  /// In en, this message translates to:
  /// **'Optional auth fallback'**
  String get mcpApiPasswordOptionalHint;

  /// No description provided for @testButton.
  ///
  /// In en, this message translates to:
  /// **'Test'**
  String get testButton;

  /// No description provided for @addButton.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get addButton;

  /// No description provided for @selectedMcpServersTitle.
  ///
  /// In en, this message translates to:
  /// **'Selected MCP Servers'**
  String get selectedMcpServersTitle;

  /// No description provided for @selectedServersCount.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String selectedServersCount(int count);

  /// No description provided for @noExternalToolsYet.
  ///
  /// In en, this message translates to:
  /// **'No remote MCP servers configured yet. Tap + to add a server URL.'**
  String get noExternalToolsYet;

  /// No description provided for @serverStatusTooltip.
  ///
  /// In en, this message translates to:
  /// **'Status: {status}'**
  String serverStatusTooltip(String status);

  /// No description provided for @statusOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get statusOnline;

  /// No description provided for @statusOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get statusOffline;

  /// No description provided for @statusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get statusUnknown;

  /// No description provided for @cloudMcpStatusLabel.
  ///
  /// In en, this message translates to:
  /// **'Cloud MCP · {status}'**
  String cloudMcpStatusLabel(String status);

  /// No description provided for @apiKeyConfiguredLabel.
  ///
  /// In en, this message translates to:
  /// **'API key configured'**
  String get apiKeyConfiguredLabel;

  /// No description provided for @apiKeyMissingLabel.
  ///
  /// In en, this message translates to:
  /// **'API key missing'**
  String get apiKeyMissingLabel;

  /// No description provided for @startPlayground.
  ///
  /// In en, this message translates to:
  /// **'Start Playground'**
  String get startPlayground;

  /// No description provided for @initialPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Optional first message — pre-filled in the chat input when Playground starts.'**
  String get initialPromptHint;

  /// No description provided for @scriptLibraryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Script Library'**
  String get scriptLibraryTooltip;

  /// No description provided for @scriptLibraryUpdated.
  ///
  /// In en, this message translates to:
  /// **'Script library updated'**
  String get scriptLibraryUpdated;

  /// No description provided for @toolboxChangesWarning.
  ///
  /// In en, this message translates to:
  /// **'Changes will reset the current session'**
  String get toolboxChangesWarning;

  /// No description provided for @toolSelectionBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get toolSelectionBuiltIn;

  /// No description provided for @toolSelectionExternal.
  ///
  /// In en, this message translates to:
  /// **'External MCP Servers'**
  String get toolSelectionExternal;

  /// No description provided for @chatSendHint.
  ///
  /// In en, this message translates to:
  /// **'Send a message to start…'**
  String get chatSendHint;

  /// No description provided for @systemPromptTapToEdit.
  ///
  /// In en, this message translates to:
  /// **'{label} (tap to edit)'**
  String systemPromptTapToEdit(String label);

  /// No description provided for @websiteUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Website URL'**
  String get websiteUrlLabel;

  /// No description provided for @maxPagesLabel.
  ///
  /// In en, this message translates to:
  /// **'Max pages'**
  String get maxPagesLabel;

  /// No description provided for @websiteUrlInvalid.
  ///
  /// In en, this message translates to:
  /// **'Typed URL is invalid.'**
  String get websiteUrlInvalid;

  /// No description provided for @websiteUrlReady.
  ///
  /// In en, this message translates to:
  /// **'Ready to add and index this URL.'**
  String get websiteUrlReady;

  /// No description provided for @websiteUrlAlreadyAdded.
  ///
  /// In en, this message translates to:
  /// **'URL already selected or max websites reached.'**
  String get websiteUrlAlreadyAdded;

  /// No description provided for @websiteUrlLimitHint.
  ///
  /// In en, this message translates to:
  /// **'Add up to 3 sites. Indexed pages are stored in DuckDB. Max pages: {maxPages}.'**
  String websiteUrlLimitHint(int maxPages);

  /// No description provided for @addUrlButton.
  ///
  /// In en, this message translates to:
  /// **'Add URL'**
  String get addUrlButton;

  /// No description provided for @noWebsitesSelected.
  ///
  /// In en, this message translates to:
  /// **'No websites selected'**
  String get noWebsitesSelected;

  /// No description provided for @websitesSelectedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} website(s) selected'**
  String websitesSelectedCount(int count);

  /// No description provided for @indexingActive.
  ///
  /// In en, this message translates to:
  /// **'Indexing…'**
  String get indexingActive;

  /// No description provided for @deleteScriptTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete script?'**
  String get deleteScriptTitle;

  /// No description provided for @deleteScriptConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"? This cannot be undone.'**
  String deleteScriptConfirm(String name);

  /// No description provided for @shellScriptLibraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Shell Script Library'**
  String get shellScriptLibraryTitle;

  /// No description provided for @newScriptTooltip.
  ///
  /// In en, this message translates to:
  /// **'New script'**
  String get newScriptTooltip;

  /// No description provided for @noScriptsYet.
  ///
  /// In en, this message translates to:
  /// **'No scripts yet.'**
  String get noScriptsYet;

  /// No description provided for @createFirstScriptHint.
  ///
  /// In en, this message translates to:
  /// **'Tap + to create a new shell script.'**
  String get createFirstScriptHint;

  /// No description provided for @createScriptButton.
  ///
  /// In en, this message translates to:
  /// **'Create Script'**
  String get createScriptButton;

  /// No description provided for @scriptDeletedMsg.
  ///
  /// In en, this message translates to:
  /// **'Deleted \"{name}\"'**
  String scriptDeletedMsg(String name);

  /// No description provided for @editScriptTooltip.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editScriptTooltip;

  /// No description provided for @deleteScriptTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteScriptTooltip;

  /// No description provided for @newShellScriptTitle.
  ///
  /// In en, this message translates to:
  /// **'New Shell Script'**
  String get newShellScriptTitle;

  /// No description provided for @editScriptDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit Script'**
  String get editScriptDialogTitle;

  /// No description provided for @scriptNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Script name'**
  String get scriptNameLabel;

  /// No description provided for @scriptNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. disk_cleanup.sh'**
  String get scriptNameHint;

  /// No description provided for @scriptDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'What does this script do?'**
  String get scriptDescriptionHint;

  /// No description provided for @generateWithAiLabel.
  ///
  /// In en, this message translates to:
  /// **'Generate with AI'**
  String get generateWithAiLabel;

  /// No description provided for @generateScriptHint.
  ///
  /// In en, this message translates to:
  /// **'Describe what the script should do…'**
  String get generateScriptHint;

  /// No description provided for @describeForGeneration.
  ///
  /// In en, this message translates to:
  /// **'Describe what the script should do.'**
  String get describeForGeneration;

  /// No description provided for @withCommentsLabel.
  ///
  /// In en, this message translates to:
  /// **'With comments'**
  String get withCommentsLabel;

  /// No description provided for @generateButton.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get generateButton;

  /// No description provided for @noLlmForScript.
  ///
  /// In en, this message translates to:
  /// **'No LLM configured. Set one in Settings or open a chat task first.'**
  String get noLlmForScript;

  /// No description provided for @scriptContentLabel.
  ///
  /// In en, this message translates to:
  /// **'Script content'**
  String get scriptContentLabel;

  /// No description provided for @insertIntoPromptButton.
  ///
  /// In en, this message translates to:
  /// **'Insert into task prompt'**
  String get insertIntoPromptButton;

  /// No description provided for @insertedIntoPromptMsg.
  ///
  /// In en, this message translates to:
  /// **'Inserted into task prompt.'**
  String get insertedIntoPromptMsg;

  /// No description provided for @scriptNameRequiredMsg.
  ///
  /// In en, this message translates to:
  /// **'Script name is required.'**
  String get scriptNameRequiredMsg;

  /// No description provided for @scriptSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String scriptSaveFailed(String error);

  /// No description provided for @scriptGenerationFailed.
  ///
  /// In en, this message translates to:
  /// **'Generation failed: {error}'**
  String scriptGenerationFailed(String error);

  /// No description provided for @sshScriptLibraryNote.
  ///
  /// In en, this message translates to:
  /// **'Scripts for SSH can be added or generated in the script library.'**
  String get sshScriptLibraryNote;

  /// No description provided for @openButtonLabel.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get openButtonLabel;

  /// No description provided for @externalMcpGlobalTitle.
  ///
  /// In en, this message translates to:
  /// **'External MCP Servers (global)'**
  String get externalMcpGlobalTitle;

  /// No description provided for @externalMcpGlobalSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Toggle which global servers are active for this task.'**
  String get externalMcpGlobalSubtitle;

  /// No description provided for @browseDriveTooltip.
  ///
  /// In en, this message translates to:
  /// **'Browse Drive'**
  String get browseDriveTooltip;

  /// No description provided for @googleDriveLabel.
  ///
  /// In en, this message translates to:
  /// **'Google Drive'**
  String get googleDriveLabel;

  /// No description provided for @noSubfoldersLabel.
  ///
  /// In en, this message translates to:
  /// **'No subfolders'**
  String get noSubfoldersLabel;

  /// No description provided for @addGoogleDriveFolder.
  ///
  /// In en, this message translates to:
  /// **'Add folder'**
  String get addGoogleDriveFolder;

  /// No description provided for @selectRootLabel.
  ///
  /// In en, this message translates to:
  /// **'Select root'**
  String get selectRootLabel;

  /// No description provided for @selectHereLabel.
  ///
  /// In en, this message translates to:
  /// **'Select here'**
  String get selectHereLabel;

  /// No description provided for @generatePromptTopicHint.
  ///
  /// In en, this message translates to:
  /// **'Topic (e.g. document search...)'**
  String get generatePromptTopicHint;

  /// No description provided for @generateLabel.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get generateLabel;

  /// No description provided for @applyLabel.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get applyLabel;

  /// No description provided for @systemPromptTitleLabel.
  ///
  /// In en, this message translates to:
  /// **'System Prompt'**
  String get systemPromptTitleLabel;

  /// No description provided for @taskPromptTitleLabel.
  ///
  /// In en, this message translates to:
  /// **'Task Prompt'**
  String get taskPromptTitleLabel;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @execInitializing.
  ///
  /// In en, this message translates to:
  /// **'Initializing task…'**
  String get execInitializing;

  /// No description provided for @execSendingPrompt.
  ///
  /// In en, this message translates to:
  /// **'Sending prompt to AI…'**
  String get execSendingPrompt;

  /// No description provided for @execAiError.
  ///
  /// In en, this message translates to:
  /// **'AI error: {error}'**
  String execAiError(String error);

  /// No description provided for @execNoResponse.
  ///
  /// In en, this message translates to:
  /// **'No response from LLM received.'**
  String get execNoResponse;

  /// No description provided for @execNoLlmResponse.
  ///
  /// In en, this message translates to:
  /// **'Empty LLM response'**
  String get execNoLlmResponse;

  /// No description provided for @execEmailSent.
  ///
  /// In en, this message translates to:
  /// **'Email sent'**
  String get execEmailSent;

  /// No description provided for @execEmailSentWithMsg.
  ///
  /// In en, this message translates to:
  /// **'Email sent: {message}'**
  String execEmailSentWithMsg(String message);

  /// No description provided for @execEmailError.
  ///
  /// In en, this message translates to:
  /// **'Email error: {error}'**
  String execEmailError(String error);

  /// No description provided for @execCompleted.
  ///
  /// In en, this message translates to:
  /// **'Execution completed.'**
  String get execCompleted;

  /// No description provided for @execError.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String execError(String error);

  /// No description provided for @execNotReady.
  ///
  /// In en, this message translates to:
  /// **'Task runtime not ready. LLM configured?'**
  String get execNotReady;

  /// No description provided for @execCheckChain.
  ///
  /// In en, this message translates to:
  /// **'Checking chain condition…'**
  String get execCheckChain;

  /// No description provided for @execChainDone.
  ///
  /// In en, this message translates to:
  /// **'Chain task executed.'**
  String get execChainDone;

  /// No description provided for @execChainError.
  ///
  /// In en, this message translates to:
  /// **'Chain error: {error}'**
  String execChainError(String error);

  /// No description provided for @applyAndReset.
  ///
  /// In en, this message translates to:
  /// **'Apply & Reset'**
  String get applyAndReset;

  /// No description provided for @noToolsAvailable.
  ///
  /// In en, this message translates to:
  /// **'No tools available'**
  String get noToolsAvailable;

  /// No description provided for @websiteIndexComplete.
  ///
  /// In en, this message translates to:
  /// **'Website index complete: {count} pages in {ms}ms'**
  String websiteIndexComplete(int count, int ms);

  /// No description provided for @invalidWebsiteUrl.
  ///
  /// In en, this message translates to:
  /// **'Invalid website URL'**
  String get invalidWebsiteUrl;

  /// No description provided for @maxWebsitesReached.
  ///
  /// In en, this message translates to:
  /// **'Maximum 3 websites allowed.'**
  String get maxWebsitesReached;

  /// No description provided for @aboutTitle.
  ///
  /// In en, this message translates to:
  /// **'About TealKit'**
  String get aboutTitle;

  /// No description provided for @userGuide.
  ///
  /// In en, this message translates to:
  /// **'User Guide'**
  String get userGuide;

  /// No description provided for @privacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get privacyPolicy;

  /// No description provided for @psScriptLibraryTitle.
  ///
  /// In en, this message translates to:
  /// **'PowerShell Script Library'**
  String get psScriptLibraryTitle;

  /// No description provided for @psNewScriptTooltip.
  ///
  /// In en, this message translates to:
  /// **'New PowerShell Script'**
  String get psNewScriptTooltip;

  /// No description provided for @psDeleteScriptTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete PowerShell Script'**
  String get psDeleteScriptTitle;

  /// No description provided for @psDeleteScriptConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String psDeleteScriptConfirm(String name);

  /// No description provided for @psScriptDeleted.
  ///
  /// In en, this message translates to:
  /// **'Deleted: {name}'**
  String psScriptDeleted(String name);

  /// No description provided for @psNoScriptsYet.
  ///
  /// In en, this message translates to:
  /// **'No PowerShell scripts yet'**
  String get psNoScriptsYet;

  /// No description provided for @psCreateFirstScriptHint.
  ///
  /// In en, this message translates to:
  /// **'Create your first PowerShell script.'**
  String get psCreateFirstScriptHint;

  /// No description provided for @psCreateScriptButton.
  ///
  /// In en, this message translates to:
  /// **'Create PowerShell Script'**
  String get psCreateScriptButton;

  /// No description provided for @psNewScriptDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'New PowerShell Script'**
  String get psNewScriptDialogTitle;

  /// No description provided for @psEditScriptDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit PowerShell Script'**
  String get psEditScriptDialogTitle;

  /// No description provided for @psScriptNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Script name is required.'**
  String get psScriptNameRequired;

  /// No description provided for @psSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: {error}'**
  String psSaveFailed(String error);

  /// No description provided for @psNoScriptContent.
  ///
  /// In en, this message translates to:
  /// **'No script content to test.'**
  String get psNoScriptContent;

  /// No description provided for @psWindowsOnlyTest.
  ///
  /// In en, this message translates to:
  /// **'PowerShell test is only available on Windows.'**
  String get psWindowsOnlyTest;

  /// No description provided for @psTestRunTitle.
  ///
  /// In en, this message translates to:
  /// **'Test Run'**
  String get psTestRunTitle;

  /// No description provided for @psTestRunParams.
  ///
  /// In en, this message translates to:
  /// **'Parameters (optional args passed to the script):'**
  String get psTestRunParams;

  /// No description provided for @psTestRunFailed.
  ///
  /// In en, this message translates to:
  /// **'Test Run Failed'**
  String get psTestRunFailed;

  /// No description provided for @psTestOutput.
  ///
  /// In en, this message translates to:
  /// **'Test Output (exit code: {code})'**
  String psTestOutput(int code);

  /// No description provided for @psRunsLocally.
  ///
  /// In en, this message translates to:
  /// **'Runs locally on this Windows machine'**
  String get psRunsLocally;

  /// No description provided for @psNoLlmConfigured.
  ///
  /// In en, this message translates to:
  /// **'No LLM configured.'**
  String get psNoLlmConfigured;

  /// No description provided for @psGenerationFailed.
  ///
  /// In en, this message translates to:
  /// **'Generation failed: {error}'**
  String psGenerationFailed(String error);

  /// No description provided for @psLoadSamplesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Load sample scripts'**
  String get psLoadSamplesTooltip;

  /// No description provided for @psSamplesLoadedMsg.
  ///
  /// In en, this message translates to:
  /// **'{count} sample scripts added.'**
  String psSamplesLoadedMsg(int count);

  /// No description provided for @vaultTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings Vault'**
  String get vaultTitle;

  /// No description provided for @vaultSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Export & import all settings, scripts and tasks — encrypted (.tkv)'**
  String get vaultSubtitle;

  /// No description provided for @vaultScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Encrypted Settings Backup'**
  String get vaultScreenTitle;

  /// No description provided for @vaultScreenDesc.
  ///
  /// In en, this message translates to:
  /// **'Save all API keys, credentials and integrations to an AES-256 encrypted file.'**
  String get vaultScreenDesc;

  /// No description provided for @vaultIncludedLabel.
  ///
  /// In en, this message translates to:
  /// **'Included (selectable per export)'**
  String get vaultIncludedLabel;

  /// No description provided for @vaultIncludedText.
  ///
  /// In en, this message translates to:
  /// **'Configuration: LLM / API keys / email / SSH / integrations\nScripts: JS  •  PowerShell  •  Python  •  SSH scripts\nTasks: all tasks with custom LLM, SSH settings & credentials'**
  String get vaultIncludedText;

  /// No description provided for @vaultExcludedLabel.
  ///
  /// In en, this message translates to:
  /// **'Never included'**
  String get vaultExcludedLabel;

  /// No description provided for @vaultExcludedText.
  ///
  /// In en, this message translates to:
  /// **'Conversation history  •  DuckDB document index'**
  String get vaultExcludedText;

  /// No description provided for @vaultExportSection.
  ///
  /// In en, this message translates to:
  /// **'Export vault'**
  String get vaultExportSection;

  /// No description provided for @vaultExportHint.
  ///
  /// In en, this message translates to:
  /// **'Choose a folder, then set filename, password and which sections to include.'**
  String get vaultExportHint;

  /// No description provided for @vaultChooseFolderExport.
  ///
  /// In en, this message translates to:
  /// **'Choose Folder & Export'**
  String get vaultChooseFolderExport;

  /// No description provided for @vaultEncrypting.
  ///
  /// In en, this message translates to:
  /// **'Encrypting...'**
  String get vaultEncrypting;

  /// No description provided for @vaultSaved.
  ///
  /// In en, this message translates to:
  /// **'Vault saved: {name}'**
  String vaultSaved(String name);

  /// No description provided for @vaultExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String vaultExportFailed(String error);

  /// No description provided for @vaultImportSection.
  ///
  /// In en, this message translates to:
  /// **'Import vault'**
  String get vaultImportSection;

  /// No description provided for @vaultImportHint.
  ///
  /// In en, this message translates to:
  /// **'Select a .tkv file to restore credentials and settings.'**
  String get vaultImportHint;

  /// No description provided for @vaultPickFileImport.
  ///
  /// In en, this message translates to:
  /// **'Pick File & Restore'**
  String get vaultPickFileImport;

  /// No description provided for @vaultDecrypting.
  ///
  /// In en, this message translates to:
  /// **'Decrypting...'**
  String get vaultDecrypting;

  /// No description provided for @vaultRestored.
  ///
  /// In en, this message translates to:
  /// **'Vault restored from {name}'**
  String vaultRestored(String name);

  /// No description provided for @vaultImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {error}'**
  String vaultImportFailed(String error);

  /// No description provided for @vaultDialogExportTitle.
  ///
  /// In en, this message translates to:
  /// **'Export Vault'**
  String get vaultDialogExportTitle;

  /// No description provided for @vaultDialogImportTitle.
  ///
  /// In en, this message translates to:
  /// **'Import Vault'**
  String get vaultDialogImportTitle;

  /// No description provided for @vaultDialogPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get vaultDialogPassword;

  /// No description provided for @vaultDialogPasswordMin.
  ///
  /// In en, this message translates to:
  /// **'Min. 8 characters'**
  String get vaultDialogPasswordMin;

  /// No description provided for @vaultDialogPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Vault password'**
  String get vaultDialogPasswordHint;

  /// No description provided for @vaultDialogPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password (min. 8 chars)'**
  String get vaultDialogPasswordLabel;

  /// No description provided for @vaultDialogConfirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm password'**
  String get vaultDialogConfirmPassword;

  /// No description provided for @vaultDialogEnterVaultPassword.
  ///
  /// In en, this message translates to:
  /// **'Enter vault password'**
  String get vaultDialogEnterVaultPassword;

  /// No description provided for @vaultDialogPasswordShort.
  ///
  /// In en, this message translates to:
  /// **'At least 8 characters'**
  String get vaultDialogPasswordShort;

  /// No description provided for @vaultPasswordMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match'**
  String get vaultPasswordMismatch;

  /// No description provided for @vaultDialogFilenameLabel.
  ///
  /// In en, this message translates to:
  /// **'Filename (.tkv)'**
  String get vaultDialogFilenameLabel;

  /// No description provided for @vaultDialogEnterFilename.
  ///
  /// In en, this message translates to:
  /// **'Enter a filename'**
  String get vaultDialogEnterFilename;

  /// No description provided for @vaultDialogIncludeLabel.
  ///
  /// In en, this message translates to:
  /// **'Include in vault:'**
  String get vaultDialogIncludeLabel;

  /// No description provided for @vaultDialogSelectRestore.
  ///
  /// In en, this message translates to:
  /// **'Select what to restore:'**
  String get vaultDialogSelectRestore;

  /// No description provided for @vaultDialogFrom.
  ///
  /// In en, this message translates to:
  /// **'From: {name}'**
  String vaultDialogFrom(String name);

  /// No description provided for @vaultSectionConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Configuration'**
  String get vaultSectionConfiguration;

  /// No description provided for @vaultSectionConfigurationDesc.
  ///
  /// In en, this message translates to:
  /// **'LLM, API keys, email, SSH, integrations, all settings'**
  String get vaultSectionConfigurationDesc;

  /// No description provided for @vaultSectionScripts.
  ///
  /// In en, this message translates to:
  /// **'Scripts'**
  String get vaultSectionScripts;

  /// No description provided for @vaultSectionScriptsDesc.
  ///
  /// In en, this message translates to:
  /// **'JS, PowerShell, Python, SSH scripts'**
  String get vaultSectionScriptsDesc;

  /// No description provided for @vaultSectionScriptsMobileDesc.
  ///
  /// In en, this message translates to:
  /// **'JS & SSH scripts (PowerShell/Python skipped on mobile)'**
  String get vaultSectionScriptsMobileDesc;

  /// No description provided for @vaultSectionTasks.
  ///
  /// In en, this message translates to:
  /// **'Tasks'**
  String get vaultSectionTasks;

  /// No description provided for @vaultSectionTasksDesc.
  ///
  /// In en, this message translates to:
  /// **'All tasks with custom LLM, SSH settings & API keys'**
  String get vaultSectionTasksDesc;

  /// No description provided for @vaultSectionSessions.
  ///
  /// In en, this message translates to:
  /// **'Playground Setups'**
  String get vaultSectionSessions;

  /// No description provided for @vaultSectionSessionsDesc.
  ///
  /// In en, this message translates to:
  /// **'Saved playground configurations (tools & prompts)'**
  String get vaultSectionSessionsDesc;

  /// No description provided for @vaultSectionSkills.
  ///
  /// In en, this message translates to:
  /// **'Tool Skills'**
  String get vaultSectionSkills;

  /// No description provided for @vaultSectionSkillsDesc.
  ///
  /// In en, this message translates to:
  /// **'LLM-generated procedural skill guides for MCP tools'**
  String get vaultSectionSkillsDesc;

  /// No description provided for @vaultGreyedNotice.
  ///
  /// In en, this message translates to:
  /// **'Greyed items are not present in this vault file.'**
  String get vaultGreyedNotice;

  /// No description provided for @vaultExportButton.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get vaultExportButton;

  /// No description provided for @vaultRestoreButton.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get vaultRestoreButton;

  /// No description provided for @skillsScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Tool Skills'**
  String get skillsScreenTitle;

  /// No description provided for @skillsScreenSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{count} skills — enabled skills are injected into system prompts for tasks that use those tools.'**
  String skillsScreenSubtitle(int count);

  /// No description provided for @skillsEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'No skills yet.\nStart a chat to trigger auto-generation.'**
  String get skillsEmptyHint;

  /// No description provided for @skillsFilterHint.
  ///
  /// In en, this message translates to:
  /// **'Filter by tool or server…'**
  String get skillsFilterHint;

  /// No description provided for @skillsCustomBadge.
  ///
  /// In en, this message translates to:
  /// **'Custom (manually edited)'**
  String get skillsCustomBadge;

  /// No description provided for @skillsMenuRegenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate non-custom'**
  String get skillsMenuRegenerate;

  /// No description provided for @skillsMenuRegenerateDesc.
  ///
  /// In en, this message translates to:
  /// **'Re-generate auto skills, keep custom ones'**
  String get skillsMenuRegenerateDesc;

  /// No description provided for @skillsMenuRebuild.
  ///
  /// In en, this message translates to:
  /// **'Rebuild (scan all tools)'**
  String get skillsMenuRebuild;

  /// No description provided for @skillsMenuRebuildDesc.
  ///
  /// In en, this message translates to:
  /// **'Overwrite all  •  or  •  add missing only'**
  String get skillsMenuRebuildDesc;

  /// No description provided for @skillsRebuildDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Rebuild skills'**
  String get skillsRebuildDialogTitle;

  /// No description provided for @skillsRebuildDialogDesc.
  ///
  /// In en, this message translates to:
  /// **'Choose how to rebuild skills for all registered MCP tools.'**
  String get skillsRebuildDialogDesc;

  /// No description provided for @skillsRebuildOverwriteTitle.
  ///
  /// In en, this message translates to:
  /// **'Overwrite all skills'**
  String get skillsRebuildOverwriteTitle;

  /// No description provided for @skillsRebuildOverwriteDesc.
  ///
  /// In en, this message translates to:
  /// **'Delete every skill (including custom ones) and regenerate all from scratch.'**
  String get skillsRebuildOverwriteDesc;

  /// No description provided for @skillsRebuildAddMissingTitle.
  ///
  /// In en, this message translates to:
  /// **'Add missing skills only'**
  String get skillsRebuildAddMissingTitle;

  /// No description provided for @skillsRebuildAddMissingDesc.
  ///
  /// In en, this message translates to:
  /// **'Keep existing skills. Generate only for tools that have no skill yet.'**
  String get skillsRebuildAddMissingDesc;

  /// No description provided for @skillsEditDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit skill: {toolName}'**
  String skillsEditDialogTitle(String toolName);

  /// No description provided for @skillsFullSkillLabel.
  ///
  /// In en, this message translates to:
  /// **'Full skill (large models)'**
  String get skillsFullSkillLabel;

  /// No description provided for @skillsSlmSkillLabel.
  ///
  /// In en, this message translates to:
  /// **'SLM skill (small / embedded models)'**
  String get skillsSlmSkillLabel;

  /// No description provided for @docFileTypesLabel.
  ///
  /// In en, this message translates to:
  /// **'File types to index'**
  String get docFileTypesLabel;

  /// No description provided for @docFileTypesReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get docFileTypesReset;

  /// No description provided for @docFileTypesAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get docFileTypesAll;

  /// No description provided for @loadModelIntoApp.
  ///
  /// In en, this message translates to:
  /// **'Load into app'**
  String get loadModelIntoApp;

  /// No description provided for @unloadModel.
  ///
  /// In en, this message translates to:
  /// **'Unload'**
  String get unloadModel;

  /// No description provided for @modelLoadedInApp.
  ///
  /// In en, this message translates to:
  /// **'In memory'**
  String get modelLoadedInApp;

  /// No description provided for @loadingModelIntoApp.
  ///
  /// In en, this message translates to:
  /// **'Loading into app…'**
  String get loadingModelIntoApp;

  /// No description provided for @loadingModelProgress.
  ///
  /// In en, this message translates to:
  /// **'Loading model… {percent}%'**
  String loadingModelProgress(int percent);

  /// No description provided for @loadModelFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load model'**
  String get loadModelFailed;

  /// No description provided for @execLoadingEmbeddedModel.
  ///
  /// In en, this message translates to:
  /// **'Loading embedded model…'**
  String get execLoadingEmbeddedModel;

  /// No description provided for @mcpRegistryInstallManuallyTooltip.
  ///
  /// In en, this message translates to:
  /// **'Install manually'**
  String get mcpRegistryInstallManuallyTooltip;

  /// No description provided for @mcpManualInstallDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Install MCP Server Manually'**
  String get mcpManualInstallDialogTitle;

  /// No description provided for @mcpManualInstallDialogSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Install an MCP server that is not listed in any registry.'**
  String get mcpManualInstallDialogSubtitle;

  /// No description provided for @mcpManualInstallNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get mcpManualInstallNameLabel;

  /// No description provided for @mcpManualInstallNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Puppeteer MCP'**
  String get mcpManualInstallNameHint;

  /// No description provided for @mcpManualInstallUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'URL (optional)'**
  String get mcpManualInstallUrlLabel;

  /// No description provided for @mcpManualInstallUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://github.com/…'**
  String get mcpManualInstallUrlHint;

  /// No description provided for @mcpManualInstallTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get mcpManualInstallTypeLabel;

  /// No description provided for @mcpManualInstallMethodLabel.
  ///
  /// In en, this message translates to:
  /// **'Method'**
  String get mcpManualInstallMethodLabel;

  /// No description provided for @mcpManualInstallTypeNodejs.
  ///
  /// In en, this message translates to:
  /// **'Node.js'**
  String get mcpManualInstallTypeNodejs;

  /// No description provided for @mcpManualInstallTypePython.
  ///
  /// In en, this message translates to:
  /// **'Python'**
  String get mcpManualInstallTypePython;

  /// No description provided for @mcpManualInstallMethodNpm.
  ///
  /// In en, this message translates to:
  /// **'npm install -g'**
  String get mcpManualInstallMethodNpm;

  /// No description provided for @mcpManualInstallMethodNpx.
  ///
  /// In en, this message translates to:
  /// **'npx (on-demand)'**
  String get mcpManualInstallMethodNpx;

  /// No description provided for @mcpManualInstallMethodUvx.
  ///
  /// In en, this message translates to:
  /// **'uvx (recommended)'**
  String get mcpManualInstallMethodUvx;

  /// No description provided for @mcpManualInstallMethodPip.
  ///
  /// In en, this message translates to:
  /// **'pip install'**
  String get mcpManualInstallMethodPip;

  /// No description provided for @mcpManualInstallPackageLabel.
  ///
  /// In en, this message translates to:
  /// **'Package / server name'**
  String get mcpManualInstallPackageLabel;

  /// No description provided for @mcpManualInstallPackageHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. puppeteer-mcp-server'**
  String get mcpManualInstallPackageHint;

  /// No description provided for @mcpManualInstallCommandLabel.
  ///
  /// In en, this message translates to:
  /// **'Install command(s)'**
  String get mcpManualInstallCommandLabel;

  /// No description provided for @mcpManualInstallCommandHint.
  ///
  /// In en, this message translates to:
  /// **'One command per line. Lines starting with # are comments.'**
  String get mcpManualInstallCommandHint;

  /// No description provided for @mcpManualInstallRegenerateTooltip.
  ///
  /// In en, this message translates to:
  /// **'Re-generate command'**
  String get mcpManualInstallRegenerateTooltip;

  /// No description provided for @mcpManualInstallExecuteSaveButton.
  ///
  /// In en, this message translates to:
  /// **'Execute & Save'**
  String get mcpManualInstallExecuteSaveButton;

  /// No description provided for @mcpManualInstallRunningButton.
  ///
  /// In en, this message translates to:
  /// **'Running…'**
  String get mcpManualInstallRunningButton;

  /// No description provided for @mcpManualInstallDoneButton.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get mcpManualInstallDoneButton;

  /// No description provided for @mcpManualInstallNoCommandsMsg.
  ///
  /// In en, this message translates to:
  /// **'No install commands to run (on-demand launcher). Registering server…'**
  String get mcpManualInstallNoCommandsMsg;

  /// No description provided for @mcpManualInstallSuccessMsg.
  ///
  /// In en, this message translates to:
  /// **'✓ Install succeeded. Saving server…'**
  String get mcpManualInstallSuccessMsg;

  /// No description provided for @mcpManualInstallSaveFailedPrefix.
  ///
  /// In en, this message translates to:
  /// **'Save failed: '**
  String get mcpManualInstallSaveFailedPrefix;

  /// No description provided for @mcpManualInstallCloseButton.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get mcpManualInstallCloseButton;

  /// No description provided for @tooltipCopyMessage.
  ///
  /// In en, this message translates to:
  /// **'Copy message'**
  String get tooltipCopyMessage;

  /// No description provided for @tooltipDownloadFile.
  ///
  /// In en, this message translates to:
  /// **'Download file'**
  String get tooltipDownloadFile;

  /// No description provided for @tooltipCopyResult.
  ///
  /// In en, this message translates to:
  /// **'Copy result'**
  String get tooltipCopyResult;

  /// No description provided for @tooltipViewAllEmails.
  ///
  /// In en, this message translates to:
  /// **'View all emails'**
  String get tooltipViewAllEmails;

  /// No description provided for @tooltipViewAllFiles.
  ///
  /// In en, this message translates to:
  /// **'View all files'**
  String get tooltipViewAllFiles;

  /// No description provided for @tooltipViewFullScreen.
  ///
  /// In en, this message translates to:
  /// **'View full screen'**
  String get tooltipViewFullScreen;

  /// No description provided for @tooltipExportToPdf.
  ///
  /// In en, this message translates to:
  /// **'Export to PDF'**
  String get tooltipExportToPdf;

  /// No description provided for @tooltipDownloadImage.
  ///
  /// In en, this message translates to:
  /// **'Download image'**
  String get tooltipDownloadImage;

  /// No description provided for @tooltipShareFile.
  ///
  /// In en, this message translates to:
  /// **'Share file'**
  String get tooltipShareFile;

  /// No description provided for @tooltipCopyFolderPath.
  ///
  /// In en, this message translates to:
  /// **'Copy folder path'**
  String get tooltipCopyFolderPath;

  /// No description provided for @tooltipFileDetails.
  ///
  /// In en, this message translates to:
  /// **'File details'**
  String get tooltipFileDetails;

  /// No description provided for @tooltipCopyAll.
  ///
  /// In en, this message translates to:
  /// **'Copy all'**
  String get tooltipCopyAll;

  /// No description provided for @tooltipReadResource.
  ///
  /// In en, this message translates to:
  /// **'Read resource'**
  String get tooltipReadResource;

  /// No description provided for @tooltipCopySchema.
  ///
  /// In en, this message translates to:
  /// **'Copy schema'**
  String get tooltipCopySchema;

  /// No description provided for @tooltipRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get tooltipRefresh;

  /// No description provided for @tooltipNewFolder.
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get tooltipNewFolder;

  /// No description provided for @tooltipUploadFile.
  ///
  /// In en, this message translates to:
  /// **'Upload file'**
  String get tooltipUploadFile;

  /// No description provided for @tooltipUploadEnterPath.
  ///
  /// In en, this message translates to:
  /// **'Upload (enter source path)'**
  String get tooltipUploadEnterPath;

  /// No description provided for @tooltipNoChanges.
  ///
  /// In en, this message translates to:
  /// **'No changes'**
  String get tooltipNoChanges;

  /// No description provided for @tooltipUploadToServer.
  ///
  /// In en, this message translates to:
  /// **'Upload to server'**
  String get tooltipUploadToServer;

  /// No description provided for @tooltipRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get tooltipRename;

  /// No description provided for @tooltipDeleteFile.
  ///
  /// In en, this message translates to:
  /// **'Delete file'**
  String get tooltipDeleteFile;

  /// No description provided for @tooltipStopProcessing.
  ///
  /// In en, this message translates to:
  /// **'Stop processing'**
  String get tooltipStopProcessing;

  /// No description provided for @tooltipExportToolList.
  ///
  /// In en, this message translates to:
  /// **'Export tool list for model training'**
  String get tooltipExportToolList;

  /// No description provided for @tooltipDiscoverTools.
  ///
  /// In en, this message translates to:
  /// **'Discover tools'**
  String get tooltipDiscoverTools;

  /// No description provided for @labelImageNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Image not available'**
  String get labelImageNotAvailable;

  /// No description provided for @labelExcelFile.
  ///
  /// In en, this message translates to:
  /// **'Excel file'**
  String get labelExcelFile;

  /// No description provided for @labelWordDocument.
  ///
  /// In en, this message translates to:
  /// **'Word document'**
  String get labelWordDocument;

  /// No description provided for @labelNoContent.
  ///
  /// In en, this message translates to:
  /// **'No content'**
  String get labelNoContent;

  /// No description provided for @labelNoResultYet.
  ///
  /// In en, this message translates to:
  /// **'No result yet'**
  String get labelNoResultYet;

  /// No description provided for @labelNoMatchingEmails.
  ///
  /// In en, this message translates to:
  /// **'No matching emails.'**
  String get labelNoMatchingEmails;

  /// No description provided for @labelFilterEmails.
  ///
  /// In en, this message translates to:
  /// **'Filter emails…'**
  String get labelFilterEmails;

  /// No description provided for @labelFileNotFound.
  ///
  /// In en, this message translates to:
  /// **'File not found at this path'**
  String get labelFileNotFound;

  /// No description provided for @labelToolNoResultData.
  ///
  /// In en, this message translates to:
  /// **'Tool executed but no result data available'**
  String get labelToolNoResultData;

  /// No description provided for @labelToolCalledNoData.
  ///
  /// In en, this message translates to:
  /// **'Tool called but no result data available'**
  String get labelToolCalledNoData;

  /// No description provided for @labelEmptyToolResult.
  ///
  /// In en, this message translates to:
  /// **'[Empty tool result]'**
  String get labelEmptyToolResult;

  /// No description provided for @labelEmailBodyEmpty.
  ///
  /// In en, this message translates to:
  /// **'Email body is empty.'**
  String get labelEmailBodyEmpty;

  /// No description provided for @labelFailedParseEmail.
  ///
  /// In en, this message translates to:
  /// **'Failed to parse email response.'**
  String get labelFailedParseEmail;

  /// No description provided for @labelShowingEmailsOf.
  ///
  /// In en, this message translates to:
  /// **'Showing {count} of {total} emails'**
  String labelShowingEmailsOf(int count, int total);

  /// No description provided for @labelEmailsCount.
  ///
  /// In en, this message translates to:
  /// **'Emails ({count})'**
  String labelEmailsCount(int count);

  /// No description provided for @dialogNewFolder.
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get dialogNewFolder;

  /// No description provided for @dialogDeleteEmptyFolder.
  ///
  /// In en, this message translates to:
  /// **'Delete empty folder'**
  String get dialogDeleteEmptyFolder;

  /// No description provided for @dialogDeleteFile.
  ///
  /// In en, this message translates to:
  /// **'Delete file'**
  String get dialogDeleteFile;

  /// No description provided for @dialogRenameFile.
  ///
  /// In en, this message translates to:
  /// **'Rename file'**
  String get dialogRenameFile;

  /// No description provided for @dialogUploadFile.
  ///
  /// In en, this message translates to:
  /// **'Upload file'**
  String get dialogUploadFile;

  /// No description provided for @dialogEditView.
  ///
  /// In en, this message translates to:
  /// **'Edit / View'**
  String get dialogEditView;

  /// No description provided for @dialogDeleteConfirmPermanent.
  ///
  /// In en, this message translates to:
  /// **'Permanently delete '**
  String get dialogDeleteConfirmPermanent;

  /// No description provided for @dialogSaveFile.
  ///
  /// In en, this message translates to:
  /// **'Save File'**
  String get dialogSaveFile;

  /// No description provided for @dialogSaveToolList.
  ///
  /// In en, this message translates to:
  /// **'Save tool list'**
  String get dialogSaveToolList;

  /// No description provided for @msgFileSaved.
  ///
  /// In en, this message translates to:
  /// **'File saved: {path}'**
  String msgFileSaved(String path);

  /// No description provided for @msgFailedDownload.
  ///
  /// In en, this message translates to:
  /// **'Failed to download file: {error}'**
  String msgFailedDownload(String error);

  /// No description provided for @msgSavedToDownloads.
  ///
  /// In en, this message translates to:
  /// **'File saved to Downloads: {fileName}'**
  String msgSavedToDownloads(String fileName);

  /// No description provided for @msgFailedSaveFile.
  ///
  /// In en, this message translates to:
  /// **'Failed to save file'**
  String get msgFailedSaveFile;

  /// No description provided for @msgSavedToPath.
  ///
  /// In en, this message translates to:
  /// **'Saved to {path}'**
  String msgSavedToPath(String path);

  /// No description provided for @msgCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get msgCopiedToClipboard;

  /// No description provided for @msgToolResultCopied.
  ///
  /// In en, this message translates to:
  /// **'Tool result copied to clipboard'**
  String get msgToolResultCopied;

  /// No description provided for @msgToolCallCopied.
  ///
  /// In en, this message translates to:
  /// **'Tool call copied to clipboard'**
  String get msgToolCallCopied;

  /// No description provided for @msgPathCopied.
  ///
  /// In en, this message translates to:
  /// **'Path copied'**
  String get msgPathCopied;

  /// No description provided for @msgConversationReset.
  ///
  /// In en, this message translates to:
  /// **'Conversation reset successfully'**
  String get msgConversationReset;

  /// No description provided for @msgImageSavedDownloads.
  ///
  /// In en, this message translates to:
  /// **'Image saved to Downloads: {fileName}'**
  String msgImageSavedDownloads(String fileName);

  /// No description provided for @msgFailedSaveImage.
  ///
  /// In en, this message translates to:
  /// **'Failed to save image'**
  String get msgFailedSaveImage;

  /// No description provided for @msgExportCancelled.
  ///
  /// In en, this message translates to:
  /// **'Export cancelled'**
  String get msgExportCancelled;

  /// No description provided for @msgExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String msgExportFailed(String error);

  /// No description provided for @msgSplitPromptInfo.
  ///
  /// In en, this message translates to:
  /// **'Split into sub-prompts — separated by ++#++'**
  String get msgSplitPromptInfo;

  /// No description provided for @msgFailedAttachFile.
  ///
  /// In en, this message translates to:
  /// **'Failed to attach file: {error}'**
  String msgFailedAttachFile(String error);

  /// No description provided for @msgFailedAttachImage.
  ///
  /// In en, this message translates to:
  /// **'Failed to attach image: {error}'**
  String msgFailedAttachImage(String error);

  /// No description provided for @msgOfficeDocNotSupported.
  ///
  /// In en, this message translates to:
  /// **'Office documents ({name}) are not supported by the AI.\n\nSupported formats:\n• Images (PNG, JPG, GIF, WebP)\n• PDF files\n• Text files\n\nPlease convert your Office document to PDF or copy the text content.'**
  String msgOfficeDocNotSupported(String name);

  /// No description provided for @msgEnterFilename.
  ///
  /// In en, this message translates to:
  /// **'Please enter a filename'**
  String get msgEnterFilename;

  /// No description provided for @msgFailedGeneratePdf.
  ///
  /// In en, this message translates to:
  /// **'Failed to generate PDF: {error}'**
  String msgFailedGeneratePdf(String error);

  /// No description provided for @msgNetworkImageExportNotSupported.
  ///
  /// In en, this message translates to:
  /// **'Network image export not supported yet'**
  String get msgNetworkImageExportNotSupported;

  /// No description provided for @labelFolderName.
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get labelFolderName;

  /// No description provided for @labelSourcePath.
  ///
  /// In en, this message translates to:
  /// **'Source path'**
  String get labelSourcePath;

  /// No description provided for @labelNewName.
  ///
  /// In en, this message translates to:
  /// **'New name'**
  String get labelNewName;

  /// No description provided for @labelRemoteTarget.
  ///
  /// In en, this message translates to:
  /// **'Remote target'**
  String get labelRemoteTarget;

  /// No description provided for @labelSearchFiles.
  ///
  /// In en, this message translates to:
  /// **'Search files...'**
  String get labelSearchFiles;

  /// No description provided for @labelNoFilesFound.
  ///
  /// In en, this message translates to:
  /// **'No files found'**
  String get labelNoFilesFound;

  /// No description provided for @labelFileName.
  ///
  /// In en, this message translates to:
  /// **'Filename'**
  String get labelFileName;

  /// No description provided for @labelEnterFilename.
  ///
  /// In en, this message translates to:
  /// **'Enter filename'**
  String get labelEnterFilename;

  /// No description provided for @hintTypeMessage.
  ///
  /// In en, this message translates to:
  /// **'Type a message...'**
  String get hintTypeMessage;

  /// No description provided for @hintAddCaption.
  ///
  /// In en, this message translates to:
  /// **'Add a caption...'**
  String get hintAddCaption;

  /// No description provided for @hintEnterSourcePath.
  ///
  /// In en, this message translates to:
  /// **'/home/user/file.txt'**
  String get hintEnterSourcePath;

  /// No description provided for @statusNoActiveTask.
  ///
  /// In en, this message translates to:
  /// **'No active task'**
  String get statusNoActiveTask;

  /// No description provided for @statusSelectTaskToSeeTools.
  ///
  /// In en, this message translates to:
  /// **'Select a task to see\navailable tools'**
  String get statusSelectTaskToSeeTools;

  /// No description provided for @statusNoToolsAvailable.
  ///
  /// In en, this message translates to:
  /// **'No tools available'**
  String get statusNoToolsAvailable;

  /// No description provided for @statusNoResourcesAvailable.
  ///
  /// In en, this message translates to:
  /// **'No resources available'**
  String get statusNoResourcesAvailable;

  /// No description provided for @statusLoadingTools.
  ///
  /// In en, this message translates to:
  /// **'Loading tools...'**
  String get statusLoadingTools;

  /// No description provided for @statusConnectToSeeTools.
  ///
  /// In en, this message translates to:
  /// **'Connect to MCP servers\nto see available tools'**
  String get statusConnectToSeeTools;

  /// No description provided for @statusNoToolsForServer.
  ///
  /// In en, this message translates to:
  /// **'No tools available for {server}'**
  String statusNoToolsForServer(String server);

  /// No description provided for @placeholderAllServers.
  ///
  /// In en, this message translates to:
  /// **'All servers'**
  String get placeholderAllServers;

  /// No description provided for @labelIncludeServerTag.
  ///
  /// In en, this message translates to:
  /// **'Include server tag'**
  String get labelIncludeServerTag;

  /// No description provided for @labelAllSelected.
  ///
  /// In en, this message translates to:
  /// **'All selected'**
  String get labelAllSelected;

  /// No description provided for @labelSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get labelSelectAll;

  /// No description provided for @splitPromptInstruction.
  ///
  /// In en, this message translates to:
  /// **'Split the user request into sequential sub-prompts. Join them with the separator ++#++ on its own line between steps. Each sub-prompt is a complete standalone instruction. Output ONLY the sub-prompts with the separator between them. No extra text.'**
  String get splitPromptInstruction;

  /// No description provided for @splitPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Split prompt into sub-prompts\n\nTap to split:\n• Lines with \\n → split instantly\n• Tap ✦ to AI-split\n\nSeparator: ++#++ (on its own line)\nInject previous tool output: \${tool_result}'**
  String splitPromptHint(Object tool_result);

  /// No description provided for @labelSplitFailed.
  ///
  /// In en, this message translates to:
  /// **'Split failed: {error}'**
  String labelSplitFailed(String error);

  /// No description provided for @renameAgentTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename Agent'**
  String get renameAgentTitle;

  /// No description provided for @agentNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get agentNameLabel;

  /// No description provided for @renameLabel.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get renameLabel;

  /// No description provided for @nextStepRoutingTitle.
  ///
  /// In en, this message translates to:
  /// **'Next Step Routing'**
  String get nextStepRoutingTitle;

  /// No description provided for @routingModeSequential.
  ///
  /// In en, this message translates to:
  /// **'Sequential (Next agent)'**
  String get routingModeSequential;

  /// No description provided for @routingModeConditional.
  ///
  /// In en, this message translates to:
  /// **'Conditional (Branch)'**
  String get routingModeConditional;

  /// No description provided for @routingModeScheduled.
  ///
  /// In en, this message translates to:
  /// **'Scheduled (Independent)'**
  String get routingModeScheduled;

  /// No description provided for @agentScheduleTitle.
  ///
  /// In en, this message translates to:
  /// **'Agent Schedule'**
  String get agentScheduleTitle;

  /// No description provided for @schedulingDisabledWarning.
  ///
  /// In en, this message translates to:
  /// **'Scheduling is disabled because this agent is called sequentially or conditionally by a previous one.'**
  String get schedulingDisabledWarning;

  /// No description provided for @tagsLabel.
  ///
  /// In en, this message translates to:
  /// **'Tags (comma separated)'**
  String get tagsLabel;

  /// No description provided for @removeAgentTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove agent'**
  String get removeAgentTooltip;

  /// No description provided for @addAgentTooltip.
  ///
  /// In en, this message translates to:
  /// **'Add agent'**
  String get addAgentTooltip;

  /// No description provided for @routingModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Routing Mode'**
  String get routingModeLabel;

  /// No description provided for @conditionRuleHeader.
  ///
  /// In en, this message translates to:
  /// **'Condition Rule #{index}'**
  String conditionRuleHeader(int index);

  /// No description provided for @removeConditionRuleTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove condition rule'**
  String get removeConditionRuleTooltip;

  /// No description provided for @targetAgentLabel.
  ///
  /// In en, this message translates to:
  /// **'Target Agent'**
  String get targetAgentLabel;

  /// No description provided for @addRoutingRuleLabel.
  ///
  /// In en, this message translates to:
  /// **'Add Routing Rule'**
  String get addRoutingRuleLabel;

  /// No description provided for @addAgentFirstWarning.
  ///
  /// In en, this message translates to:
  /// **'Add another agent first to configure conditional routing.'**
  String get addAgentFirstWarning;

  /// No description provided for @operatorLabel.
  ///
  /// In en, this message translates to:
  /// **'Operator'**
  String get operatorLabel;

  /// No description provided for @customExpressionLabel.
  ///
  /// In en, this message translates to:
  /// **'Custom Expression'**
  String get customExpressionLabel;

  /// No description provided for @customExpressionHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. avg value > 5'**
  String get customExpressionHint;

  /// No description provided for @valueLabel.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get valueLabel;

  /// No description provided for @valueHint.
  ///
  /// In en, this message translates to:
  /// **'Value to compare'**
  String get valueHint;

  /// No description provided for @agentScheduleHeader.
  ///
  /// In en, this message translates to:
  /// **'Agent Schedule'**
  String get agentScheduleHeader;

  /// No description provided for @operatorLess.
  ///
  /// In en, this message translates to:
  /// **'Less (<)'**
  String get operatorLess;

  /// No description provided for @operatorLessOrEquals.
  ///
  /// In en, this message translates to:
  /// **'Less or Equals (<=)'**
  String get operatorLessOrEquals;

  /// No description provided for @operatorEquals.
  ///
  /// In en, this message translates to:
  /// **'Equals (==)'**
  String get operatorEquals;

  /// No description provided for @operatorNotEqual.
  ///
  /// In en, this message translates to:
  /// **'Not Equal (!=)'**
  String get operatorNotEqual;

  /// No description provided for @operatorGreaterThan.
  ///
  /// In en, this message translates to:
  /// **'More (>)'**
  String get operatorGreaterThan;

  /// No description provided for @operatorGreaterOrEquals.
  ///
  /// In en, this message translates to:
  /// **'More or Equals (>=)'**
  String get operatorGreaterOrEquals;

  /// No description provided for @operatorContains.
  ///
  /// In en, this message translates to:
  /// **'Contains'**
  String get operatorContains;

  /// No description provided for @operatorNotContains.
  ///
  /// In en, this message translates to:
  /// **'Not Contains'**
  String get operatorNotContains;

  /// No description provided for @operatorCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom Expression'**
  String get operatorCustom;

  /// No description provided for @operatorLlmEval.
  ///
  /// In en, this message translates to:
  /// **'Evaluated by LLM'**
  String get operatorLlmEval;

  /// No description provided for @llmConditionLabel.
  ///
  /// In en, this message translates to:
  /// **'Condition to evaluate'**
  String get llmConditionLabel;

  /// No description provided for @llmConditionHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. battery voltage > 5'**
  String get llmConditionHint;

  /// No description provided for @cancelExecution.
  ///
  /// In en, this message translates to:
  /// **'Cancel execution'**
  String get cancelExecution;

  /// No description provided for @inactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get inactive;

  /// No description provided for @noAgentLogs.
  ///
  /// In en, this message translates to:
  /// **'No execution logs recorded for this workflow.'**
  String get noAgentLogs;

  /// No description provided for @agentLogsTitle.
  ///
  /// In en, this message translates to:
  /// **'Execution Logs: {name}'**
  String agentLogsTitle(String name);

  /// No description provided for @skillLlmNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'The LLM configured in this skill ({provider} / {model}) is not available. Using the default LLM instead.'**
  String skillLlmNotConfigured(String provider, String model);

  /// No description provided for @llmWarning.
  ///
  /// In en, this message translates to:
  /// **'LLM Warning'**
  String get llmWarning;

  /// No description provided for @loadWorkflowsAndImportSkills.
  ///
  /// In en, this message translates to:
  /// **'Load Workflows / Import Skills'**
  String get loadWorkflowsAndImportSkills;

  /// No description provided for @resetPlayground.
  ///
  /// In en, this message translates to:
  /// **'Reset Playground'**
  String get resetPlayground;

  /// No description provided for @toolWarning.
  ///
  /// In en, this message translates to:
  /// **'Tool Warning'**
  String get toolWarning;

  /// No description provided for @skillRequiresTools.
  ///
  /// In en, this message translates to:
  /// **'This skill requires tool(s): {tools}. Please install/register if not exists or select from the toolset.'**
  String skillRequiresTools(String tools);
}

class _LDelegate extends LocalizationsDelegate<L> {
  const _LDelegate();

  @override
  Future<L> load(Locale locale) {
    return SynchronousFuture<L>(lookupL(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_LDelegate old) => false;
}

L lookupL(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return LDe();
    case 'en':
      return LEn();
  }

  throw FlutterError(
    'L.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
