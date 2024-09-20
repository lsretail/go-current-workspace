
import {PowerShell} from '../../PowerShell'
import {PackageInfo} from '../../interfaces/packageInfo';
import { Server, Package } from '../../models/projectFile';
import { GoCurrentVersion } from '../../interfaces/goCurrentVersion';
import { parse } from 'path';

export class DeployPsService
{
    private _modulePath: string;
    private _imported: boolean = false;
    private _powerShell: PowerShell;
    private _isAdmin: boolean;

    constructor(powerShell: PowerShell, modulePath: string)
    {
        this._powerShell = powerShell;
        this._modulePath = modulePath;
    }

    public async isAdmin(): Promise<boolean>
    {
        if (!this._isAdmin)
            this._isAdmin = await this._powerShell.executeCommandSafe("Test-AdminAsJson", true);
        return this._isAdmin;
    }

    private executeCommandSafe(commandName: string, parseJson: boolean, ...args: any[]) : Promise<any>
    {
        this.init();
        return this._powerShell.executeCommandSafe(commandName, parseJson, ...args);
    }

    private init()
    {
        if (!this._imported)
        {
            this._imported = true;
            this._powerShell.addModuleFromPath(this._modulePath);
            this._powerShell.setPreCommand("trap{if (Invoke-ErrorHandler $_) { continue };}");
        }
    }

    private async executeAsAdmin(commandName: string, parseJson: boolean, ...args: any[]) : Promise<any>
    {
        if (await this.isAdmin())
        {
            return this.executeCommandSafe(commandName, parseJson, ...args);
        }
        else
        {
            return this.executeCommandSafe(commandName + "Admin", parseJson, ...args);
        }
    }

    public getTestString(): Promise<string>
    {
        let param = {
            'Value': 'input parameter'
        }
        return this.executeCommandSafe("Get-TestString", false, param);
    }

    public async installPackageGroup(
        projectFilePath: string,
        packageGroupId: string,
        instanceName: string,
        target: string,
        branchName: string,
        servers: Server[]
    ) : Promise<PackageInfo[]>
    {
        let param = {
            'ProjectFilePath': `'${projectFilePath}'`,
        }

        if (packageGroupId)
            param['packageGroupId'] = `'${packageGroupId}'`;

        if (instanceName)
            param['InstanceName'] = `'${instanceName}'`;

        if (target)
            param['Target'] = `'${target}'`;

        if (branchName)
            param['BranchName'] = `'${branchName}'`;

        if (servers)
            param['Servers'] = `'${JSON.stringify(servers)}'`;

        this.init();
        let powerShell = this._powerShell.getNewPowerShell();
        try
        {
            let result = await powerShell.executeCommandSafe("Install-PackageGroup", true, param);
            return result;
        }
        finally
        {
            powerShell.dispose();
        }
    }

    public getAvailableUpdates(
        projectFilePath: string,
        packageGroupId: string,
        instanceName: string,
        branchName: string,
        target: string,
        servers: Server[]
    )
    {
        let param = {
            'ProjectFilePath': `'${projectFilePath}'`,
        }

        if (packageGroupId)
            param['PackageGroupId'] = `'${packageGroupId}'`;

        if (instanceName)
            param['InstanceName'] = `'${instanceName}'`;

        if (target)
            param['Target'] = `'${target}'`;

        if (branchName)
            param['BranchName'] = `'${branchName}'`;

        if (servers)
            param['Servers'] = `'${JSON.stringify(servers)}'`;

        return this.executeCommandSafe("Get-AvailableUpdates", true, param);
    }

    public removeDeployment(workspaceDataPath: string, deploymentGuid: string) : Promise<any>
    {
        let param = {
            'WorkspaceDataPath': `'${workspaceDataPath}'`,
            'DeploymentGuid': `'${deploymentGuid}'`,
        }
        return this.executeAsAdmin("Remove-Deployment", true, param);
    }

    public testIsInstance(
        projectFilePath: string,
        packageGroupId: string,
        servers: Server[],
        target?: string,
        branchName?: string,
    ) : Promise<any>
    {
        let param = {
            'ProjectFilePath': `'${projectFilePath}'`,
            'packageGroupId': `'${packageGroupId}'`
        };

        if (target)
            param['Target'] = `'${target}'`;

        if (branchName)
            param['BranchName'] = `'${branchName}'`;

        if (servers)
            param['Servers'] = `'${JSON.stringify(servers)}'`;

        return this.executeCommandSafe("Test-IsInstance", true, param);
    }

    public testCanInstall(
        projectFilePath: string,
        packageGroupId: string,
        target?: string,
        branchName?: string,
    ): Promise<boolean>
    {
        const param = {
            "ProjectFilePath": projectFilePath,
            "packageGroupId": packageGroupId
        }

        if (target)
            param['Target'] = `'${target}'`;

        if (branchName)
            param['BranchName'] = `'${branchName}'`;

        return this.executeCommandSafe("Test-CanInstall", true, param);
    }

    public getDeployedPackages(workspaceDataPath: string, deploymentGuid: string) : Promise<PackageInfo[]>
    {
         let param = {
            'WorkspaceDataPath': `'${workspaceDataPath}'`,
            'DeploymentGuid': `'${deploymentGuid}'`,
        }
        return this.executeCommandSafe("Get-DeployedPackages", true, param);
    }

    public getTargets(projectFilePath: string, id?: string, useDevTarget?: boolean): Promise<string[]>
    {
        let param = {
            projectFilePath: `'${projectFilePath}'`,
            useDevTarget: false
        }

        if (id)
            param['id'] = `'${id}'`;

        if (useDevTarget !== undefined)
            param['useDevTarget'] = useDevTarget;

        return this.executeCommandSafe("Get-Targets", true, param);
    }

    public getResolvedProjectFile(projectFilePath: string, target: string, branchName: string): Promise<object>
    {
        let param = {
            projectFilePath: `'${projectFilePath}'`,
            target: `'${target}'`,
            branchName: `'${branchName}'`
        }
        return this.executeCommandSafe("Get-ResolvedProjectFile", true, param);
    }

    public getPackageGroup(projectFilePath: string, id: string, target: string, branchName: string): Promise<object>
    {
        let param = {
            projectFilePath: `'${projectFilePath}'`,
            packageGroupId:  `'${id}'`,
            target: `'${target}'`,
            branchName: `'${branchName}'`
        }
        return this.executeCommandSafe("Get-ResolvedPackageGroup", true, param);
    }
}