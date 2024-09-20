
import {PowerShell} from '../../PowerShell'
import {PackageInfo} from '../../interfaces/packageInfo';
import { Server, Package } from '../../models/projectFile';
import { GoCurrentVersion } from '../../interfaces/goCurrentVersion';
import { Event, EventEmitter } from 'vscode';
import { PackageWithName } from '../interfaces/packageWithName';

export class GoCurrentPsService
{
    private _modulePath: string;

    private _powerShell: PowerShell;
    private _isAdmin: boolean;
    private _isInstalled: boolean = undefined;
    private _onDidInitialize = new EventEmitter<GoCurrentPsService>();

    constructor(powerShell: PowerShell, modulePath: string)
    {
        this._powerShell = powerShell;
        this._powerShell.addModuleFromPath(modulePath);
        this._powerShell.setRunWithNext("$WarningPreference = 'SilentlyContinue'");
        this._powerShell.setPreCommand("trap{if (Invoke-ErrorHandler $_) { continue };}");
        this._modulePath = modulePath;
    }

    public get onDidInitilize(): Event<GoCurrentPsService>
    {
        return this._onDidInitialize.event;
    }

    public get powerShell()
    {
        return this._powerShell;
    }

    public async isAdmin(): Promise<boolean>
    {
        if (!this._isAdmin)
            this._isAdmin = await this._powerShell.executeCommandSafe("Test-AdminAsJson", true);
        return this._isAdmin;
    }

    private async executeAsAdmin(commandName: string, parseJson: boolean, ...args: any[]) : Promise<any>
    {
        if (await this.isAdmin())
        {
            return this._powerShell.executeCommandSafe(commandName, parseJson, ...args);
        }
        else
        {
            return this._powerShell.executeCommandSafe(commandName + "Admin", parseJson, ...args);
        }
    }

    public get isInitialized(): boolean
    {
        return this._isInstalled !== undefined
    }

    public isGocInstalled(): boolean
    {
        if (this._isInstalled === undefined)
        {
            return true;
        }
        return this._isInstalled;
    }

    public async getGoCurrentVersion(): Promise<GoCurrentVersion>
    {
        let gocVersion: GoCurrentVersion = await this._powerShell.executeCommandSafe("Get-GoCurrentVersion", true);
        let isInitialized = this.isInitialized;
        this._isInstalled = gocVersion.IsInstalled && gocVersion.HasRequiredVersion;

        if (!isInitialized)
            this._onDidInitialize.fire(this);

        return gocVersion;
    }

    public async installPackages(
        packages: Package[],
        instanceName?: string,
        servers?: Server[]

    ) : Promise<PackageInfo[]>
    {
        let param = {
            packages: `'${JSON.stringify(packages)}'`
        }

        if (instanceName)
            param['InstanceName'] = `'${instanceName}'`;

        if (servers)
            param['Servers'] = `'${JSON.stringify(servers)}'`;

        let powerShell = this._powerShell.getNewPowerShell();
        try
        {
            return await powerShell.executeCommandSafe("Install-PackagesJson", true, param);
        }
        finally
        {
            powerShell.dispose();
        }
    }

    public getUpdates(
        packages: Package[],
        instanceName?: string,
        servers?: Server[]
    ): Promise<PackageInfo[]>
    {
        let param = {
            packages: `'${JSON.stringify(packages)}'`
        }

        if (instanceName)
            param['InstanceName'] = `'${instanceName}'`;

        if (servers)
            param['Servers'] = `'${JSON.stringify(servers)}'`;

        return this._powerShell.executeCommandSafe("Get-Updates", true, param);
    }

    public getPackage(
        packageId: string,
        versionQuery: string,
        servers?: Server[]
    ): Promise<PackageWithName>
    {
        let param = {
            packageId: `'${packageId}'`,
            versionQuery: `'${versionQuery}'`
        }

        if (servers)
            param['Servers'] = `'${JSON.stringify(servers)}'`;

        return this._powerShell.executeCommandSafe("Get-Package", true, param);
    }

    public testNewerVersion(newVersion: string, oldVersion: string): Promise<boolean>
    {
        let param = {
            newVersion: newVersion,
            oldVersion: oldVersion
        }
        return this._powerShell.executeCommandSafe("Test-NewerVersion", true, param);
    }

    public testPackageAvailable(packageId: string, servers?: Server[])
    {
        let param = {
            PackageId: `'${packageId}'`
        }

        if (servers)
            param['Servers'] = `'${JSON.stringify(servers)}'`;

        return this._powerShell.executeCommandSafe("Test-PackageAvailable", true, param);
    }

    public testInstanceExists(instanceName: string): Promise<boolean>
    {
        return this._powerShell.executeCommandSafe("Test-InstanceExists", true, {"InstanceName": instanceName});
    }

    public isInstalled(packages: string[], instanceName?: string): Promise<boolean>
    {
        let args = {
            any: true
        };

        if (packages && packages.length > 0)
            args["Packages"] = packages;

        if (instanceName)
            args["InstanceName"] = instanceName;

        return this._powerShell.executeCommandSafe("Test-IsInstalled", true, args)
    }

    public filterInstalled(packages: string[], instanceName?: string): Promise<string[]>
    {
        let args = {};

        if (packages && packages.length > 0)
            args["Packages"] = packages;

        if (instanceName)
            args["InstanceName"] = instanceName;

        return this._powerShell.executeCommandSafe("Test-IsInstalled", true, args)
    }

    public getInstalledPackages(id: string, instanceName: string = undefined) : Promise<PackageInfo[]>
    {
        let param = {
            'Id': id
        };
        if (instanceName)
            param['InstanceName'] = instanceName;

        return this._powerShell.executeCommandSafe("Get-InstalledPackages", true, param);
    }

    public getInstances() : Promise<PackageInfo[][]>
    {
        return this._powerShell.executeCommandSafe("Get-Instances", true);
    }

    public openGoCurrentWizard()
    {
        this._powerShell.executeCommandSafe("Invoke-OpenGoCurrentWizard", false);
    }
}