import { WorkspaceData } from "../../models/workspaceData";
import { ProjectFile } from "../../models/projectFile";
import { JsonData } from "../../jsonData";
import { PackagePsService } from "./packagePsService";
import { AlExtensionService } from "./alExtensionService";
import { fsHelpers } from "../../fsHelpers";
import { IWorkspaceService } from "../../workspaceService/interfaces/IWorkspaceService";
import path = require("path");
import { AppJson } from "../../newProjectService/interfaces/appJson";
import { WorkspaceHelpers } from "../../helpers/workspaceHelpers";
import { PowerShellError } from "../../PowerShell";

export class PackageService implements IWorkspaceService
{
    private _packagesPsService: PackagePsService;
    private _projectFile: JsonData<ProjectFile>;
    private _appJson: JsonData<AppJson>;
    private _alExtensionService: AlExtensionService;

    public constructor(
        packagePsService: PackagePsService,
        alExtensionService: AlExtensionService,
        projectFile: JsonData<ProjectFile>,
        appJson: JsonData<AppJson> 
    )
    {
        this._projectFile = projectFile;
        this._packagesPsService = packagePsService;
        this._alExtensionService = alExtensionService;
        this._appJson = appJson;
    }

    async isActive(): Promise<boolean> 
    {
        return true;
    }
    
    async dispose(): Promise<void> 
    {
        // ignore
    }

    getTargets(id?: string, useDevTarget?: boolean): Promise<string[]>
    {
        return this._packagesPsService.getTargets(this._projectFile.uri.fsPath, id, useDevTarget);
    }

    newPackage(target: string, branchName: string, defaultOutputDir: string): Promise<string>
    {
        return this._packagesPsService.newPackage(this._projectFile.uri.fsPath, target, branchName, defaultOutputDir);
    }

    async newAlPackage(projectDir: string, target: string, branchName: string): Promise<string>
    {
        return this._packagesPsService.newAlPackage(projectDir, await this.getAppFileName(true), this._projectFile.uri.fsPath, target, branchName);
    }
    async importPackage(path: string, server: string, port: number, force: boolean): Promise<void>
    {
        return await this._packagesPsService.importPackage(path, server, port, force);
    }

    async invokeAlCompileAndPackage(
        projectDir: string, 
        target: string,
        branchName: string,
        skipPackages: string[],
        outputChannel: (message: string) => void
    ) : Promise<string>
    {
        if (!this._alExtensionService.isInstalled)
            throw "AL Language extension not installed."

        if (!outputChannel)
            outputChannel = message => {};

        let tempDir = await this._packagesPsService.newTempDir();

        try
        {
            outputChannel("Downloading dependencies ...");

            let packageCachePath = path.join(tempDir, '.alpackages');
            let assemblyProbingPath = path.join(tempDir, '.netpackages');

            let output = await this._packagesPsService.getDependencies(
                projectDir, 
                this._projectFile.uri.fsPath, 
                target, 
                branchName,
                packageCachePath,
                assemblyProbingPath,
                skipPackages
            );
            outputChannel(output);
    
            outputChannel("Compiling app ...");
            try
            {
                output = await this._packagesPsService.invokeCompile(
                    projectDir, 
                    this._alExtensionService.compilerPath, 
                    tempDir
                );
                outputChannel(output);
            }
            catch (error)
            {
                let errorOutput = this.getVerbose(error);
                if (errorOutput.length > 0)
                    outputChannel(errorOutput);
                throw error;
            }
    
            outputChannel("Creating package ...");
            let packagePath = await this.newAlPackage(projectDir, target, branchName);
            outputChannel(`Package created at "${packagePath}"`);
            return packagePath;
        }
        finally
        {
            try
            {
                fsHelpers.rmDir(tempDir, true);
            }
            catch (e)
            {
                // ignore
            }            
        }
        
    }

    private getVerbose(error: PowerShellError | any): string
    {
        if (!(error instanceof PowerShellError))
            return "";

        let errorStart = '!!!'
        try
        {
            return (<string>error.rawError.message.split(errorStart)[0]).trim();
        }
        catch
        {
            // Ignore
        }
        return "";
    }

    public async downloadAlDependencies(
        projectDir: string, 
        target: string, 
        branchName: string,
        skipPackages: string[]
    ): Promise<{output: string, dllsLocked: boolean}>
    {
        if (!this._alExtensionService.isInstalled)
            throw "AL Language extension not installed."

        let workspaceFolder = WorkspaceHelpers.getWorkspaceForPath(projectDir);

        let alConfig = this._alExtensionService.getConfig(workspaceFolder);
        let assemblyProbingDir = this.getFirstRelativePath(alConfig.assemblyProbingPaths, '.netpackages');

        let dllsLocked = await this._packagesPsService.testNetPackagesLocked(projectDir, assemblyProbingDir);

        let output = await this._packagesPsService.getDependencies(
            projectDir, 
            this._projectFile.uri.fsPath, 
            target, 
            branchName,
            alConfig.packageCachePath,
            assemblyProbingDir,
            skipPackages
        );

        return {output: output, dllsLocked: dllsLocked};
    }

    private getFirstRelativePath(paths: string[], defaultValue: string): string
    {
        for (let item of paths)
        {
            if (!path.isAbsolute(item))
            {
                return item;
            }
        }
        return defaultValue;
    }

    private delay(ms: number): Promise<void>
    {
        return new Promise( resolve => setTimeout(resolve, ms) );
    }

    public async getAppFileName(includeDir: boolean): Promise<string>
    {
        let data = await this._appJson.getData();
        let fileName = `${data.publisher}_${data.name}_${data.version}.app`

        if (includeDir)
            return path.join(path.dirname(this._appJson.uri.fsPath), fileName);
        return fileName;
    }
}