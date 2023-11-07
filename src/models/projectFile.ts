

export class ProjectFile
{
    id: string;
    name: string;
    description: string;
    displayName: string;
    devTarget: string | string[];
    variables: {[key:string]: any};
    dependencies: Array<ProjectFilePackage>;
    devPackageGroups: PackageGroup[];
    servers: Server[];
}

export class PackageGroup
{
    id: string;
    name: string;
    description: string;
    packages: ProjectFilePackage[]
    instanceName: string;
    instanceNameSuggestion: string;
    devTarget: string | string[];
    servers: Server[];
    arguments: {[key: string]: {[key: string]: string}}
}

export class Package
{
    constructor(id?: string, version?: string)
    {
        if (id)
            this.id = id;
        
        if (version !== undefined)
            this.version = version;
    }

    id: string;
    version: string;
    optional?: boolean;
}

export class ProjectFilePackage
{
    id: string;
    version: string | VersionFromAlApp | any;
    onlyRestrictVersion?: boolean;
    optional?: boolean;
}

export class VersionFromAlApp
{
    alAppId: string;
    alAppIdParts: number;
    alAppIdType: string;
}

export class Server
{
    guid: string;
    host: string;
    port?: number;
    managementPort?: number;
    useSsl: boolean;
    identity: string;
}