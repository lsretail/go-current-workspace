import { commands, window, ExtensionContext, workspace, Uri } from 'vscode';
import * as vscode from 'vscode'
import { Constants } from '../constants';
import { DeployService } from '../deployService/services/deployService';
import { UiService } from "../extensionController";
import { GoCurrentPsService } from '../goCurrentService/services/goCurrentPsService';
import { UiHelpers } from '../helpers/uiHelpers';
import { NewProjectService } from '../newProjectService/services/newProjectService';
import Resources from '../resources';
import { WorkspaceFilesService } from '../services/workspaceFilesService';
import { WorkspaceServiceProvider, WorkspaceContainerEvent } from '../workspaceService/services/workspaceServiceProvider';
import { Package } from '../models/projectFile';
import path = require('path');
import { fsHelpers } from '../fsHelpers';
import { format } from 'util';
import { InstallHelpers } from '../helpers/installHelpers';
import { Logger } from '../interfaces/logger';
import { WorkspaceHelpers } from '../helpers/workspaceHelpers';

export class BaseUiService extends UiService
{
    private _goCurrentPsService: GoCurrentPsService;
    private _wsDeployServices: WorkspaceServiceProvider<DeployService>;
    private _wsWorkspaceFileServices: WorkspaceServiceProvider<WorkspaceFilesService>;
    private _disposable: vscode.Disposable;

    constructor(
        context: ExtensionContext,
        logger: Logger,
        goCurrentPsService: GoCurrentPsService,
        wsDeployServices: WorkspaceServiceProvider<DeployService>,
        wsWorkspaceFileServices: WorkspaceServiceProvider<WorkspaceFilesService>
    )
    {
        super(context, logger);
        this._goCurrentPsService = goCurrentPsService;
        this._wsDeployServices = wsDeployServices;
        this._wsWorkspaceFileServices = wsWorkspaceFileServices;
    }

    async activate(): Promise<void>
    {
        this.registerCommand("ls-update-service.newProject", this.newProject);
        this.registerCommand("ls-update-service.openWizard", this.openWizard);

        commands.executeCommand("setContext", Constants.goCurrentExtensionActive, true);

        let subscriptions: vscode.Disposable[] = [];
        this._wsWorkspaceFileServices.onDidChangeWorkspaceFolders(this.onWorkspaceChanges, this, subscriptions);
        this._disposable = vscode.Disposable.from(...subscriptions);

        await this.checkGoCurrentInstalled();
    }

    private onWorkspaceChanges(e: WorkspaceContainerEvent<WorkspaceFilesService>)
    {
        this.checkAndUpdateIfActive();
        for (let workspaceFolder of e.workspaceChanges.added)
        {
            let subscriptions: vscode.Disposable[] = [];

            let service = e.workspaceContainer.getService(workspaceFolder);

            service.projectFile.onDidChange(e => {
                this.checkAndUpdateIfActive();
            }, subscriptions);

            e.pushSubscription(workspaceFolder, vscode.Disposable.from(...subscriptions));
        }
    }

    private async checkAndUpdateIfActive()
    {
        let anyActive = await this._wsWorkspaceFileServices.anyActive();
        let anyInactive = await this._wsWorkspaceFileServices.anyInactive();

        commands.executeCommand("setContext", Constants.goCurrentProjectFileActive, anyActive);
        commands.executeCommand("setContext", Constants.goCurrentProjectFileHasInactiveWorkspaces, anyInactive);
    }

    openWizard()
    {
        this._goCurrentPsService.openGoCurrentWizard();
    }

    private async checkGoCurrentInstalled()
    {
        let gocVersion = await this._goCurrentPsService.getGoCurrentVersion();
        let goCurrentInstalled = gocVersion.IsInstalled;

        if (!goCurrentInstalled || !gocVersion.HasRequiredVersion)
        {
            commands.executeCommand("setContext", Constants.goCurrentExtensionActive, false);
            commands.executeCommand("setContext", Constants.goCurrentDeployActive, false);
            commands.executeCommand("setContext", Constants.goCurrentAlActive, false);
            commands.executeCommand("setContext", Constants.goCurrentDeployUpdatesAvailable, false);

            let message = "Go Current is not installed, extension will not load.";
            let buttons = [Constants.buttonVisitWebsite];
            if (goCurrentInstalled && !gocVersion.HasRequiredVersion)
            {
                message = `You do not have the required version of the Go Current client, v${gocVersion.RequiredVersion}, you have v${gocVersion.CurrentVersion}. Please update and reload your workspace.`;
             
                let packageObj: Package = { id: "go-current-client", version: ""};
                let updates = await this._goCurrentPsService.getUpdates([packageObj]);

                if (updates.length > 0)
                    buttons = [Constants.buttonUpdate, Constants.buttonLater];
            }

            let result = await window.showWarningMessage(message, ...buttons);
            if (result === Constants.buttonVisitWebsite)
            {
                vscode.env.openExternal(Uri.parse(Constants.gocHelpUrl));
            }
            else if (result === Constants.buttonUpdate)
            {
                InstallHelpers.installPackage("go-current-client", this._goCurrentPsService, {reload: true, reloadText: Resources.goCurrentUpdated})
            }
        }
        else
        {
            this.checkForBaseUpdate();
        }
    }

    public static async checkForGocWorkspaceUpdates(goCurrentPsService: GoCurrentPsService, context: ExtensionContext): Promise<boolean>
    {
        let packageId = 'ls-update-service-workspace'
        
        if (!await goCurrentPsService.testPackageAvailable(packageId))
            return false;

        let packageObj: Package = { id: packageId, version: ""};
        let updates = await goCurrentPsService.getUpdates([packageObj]);

        if (updates.length === 0)
            return false;

        let newVersion = updates.filter(p => p.Id === packageId)[0].Version;
        let currentVersion = await this.getCurrentVersion(context);

        let isNewer = await goCurrentPsService.testNewerVersion(newVersion, currentVersion);

        if (!isNewer)
            return false;

        window.showInformationMessage(format(Resources.gocWorkspaceUpdateAvailable, newVersion), Constants.buttonUpdate).then(result => 
        {
            if (result !== Constants.buttonUpdate)
            return;
        
            InstallHelpers.installPackage(packageId, goCurrentPsService, {reload: true, reloadText: Resources.gocWorkspaceUpdated});    
        });

        return true;
    }

    public static async checkForUpdates(packages: string[], goCurrentPsService: GoCurrentPsService): Promise<boolean>
    {
        packages = await goCurrentPsService.filterInstalled(packages);

        let updates = await goCurrentPsService.getUpdates(packages.map(p => new Package(p, "")));

        for (let update of updates)
        {
            let packageItem = await goCurrentPsService.getPackage(update.Id, "");
            window.showInformationMessage(format(Resources.updateAvailable, packageItem.Name, update.Version.split('+')[0]), Constants.buttonUpdate, Constants.buttonLater).then(result => 
            {
                if (result === Constants.buttonUpdate)
                {
                    InstallHelpers.installPackage(update.Id, goCurrentPsService, {restartPowerShell: true});
                }
            });
        }
        return updates.length > 0;
    }

    private static async getCurrentVersion(context: ExtensionContext): Promise<string>
    {
        let packagePath = path.join(context.extensionUri.fsPath, 'package.json');
        if (!fsHelpers.existsSync(packagePath))
            return;

        let jsonContent = JSON.parse(await fsHelpers.readFile(packagePath));
        return jsonContent.version
    }

    private async checkForBaseUpdate()
    {
        await BaseUiService.checkForGocWorkspaceUpdates(this._goCurrentPsService, this.context);
        await BaseUiService.checkForUpdates(["go-current-server", "go-current-client", "ls-package-tools"], this._goCurrentPsService);
    }

    private async newProject()
    {
        let workspaceFolder = await UiHelpers.showWorkspaceFolderPick(await this._wsDeployServices.getWorkspaces({active: false}));

        if (!workspaceFolder)
            return

        let newProjectService = new NewProjectService(workspaceFolder);

        let newProjectFilePath: string;
        if (newProjectService.isAl())
        {
            let appIdToPackageIdMap = await WorkspaceHelpers.getAppIdPackageIdMapFromWorkspaces(this._wsWorkspaceFileServices);
            newProjectFilePath = await newProjectService.newAlProject(this.context, appIdToPackageIdMap);
        }
        else
        {
            newProjectFilePath = await newProjectService.newProject(this.context);
        }        

        let document = await workspace.openTextDocument(newProjectFilePath)
        await window.showTextDocument(document);

        if (!newProjectService.isAl())
        {
            let packageId = await window.showInputBox({
                value: "your-package-id",
                ignoreFocusOut: true,
                prompt: "Specify package ID"
            })
    
            await newProjectService.updateProperty({id: packageId});
        }
        else
        {
            let choice = await window.showQuickPick([
                Resources.addLicensePackage,
                Resources.chooseLicenseFile,
                Resources.skipLicenseForNow

            ], {
                placeHolder: "Add license for your Business Central development instance.", 
                ignoreFocusOut: true,
            })

            if (choice === Resources.chooseLicenseFile)
            {
                let licenseFile = await window.showOpenDialog({
                    canSelectFiles: true, 
                    defaultUri: workspaceFolder.uri,
                    filters: {'License files (*.flf, *.bclicense)': ['flf', 'bclicense']},
                    title: "Select license file",
                    openLabel: "Select License"
                });
                if (licenseFile)
                {
                    await newProjectService.addLicenseFile(licenseFile[0].fsPath);
                }
            }
            else if (choice === Resources.addLicensePackage)
            {
                let licensePackageId = await window.showInputBox({prompt: Resources.specifyLicensePackage, ignoreFocusOut: true});
                if (licensePackageId)
                {
                    await newProjectService.addLicensePackage(licensePackageId);
                }
            }
        }

        newProjectService.dispose();
    }
}