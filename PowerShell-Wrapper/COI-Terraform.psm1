# -- Shared variables --
$Script:Vars = @{
    Credentials = $null
    no_clean = $null
    repo_url = '//dfsserv2.hh.nku.edu/it - infrastructure$/Server Team/Git/COI-Terraform/COI-Terraform/'
    local_repo = "$($HOME)\COI\Terraform"
    current_dir = (Get-Location)
    no_warn = $false
    environment_variables = @(
        "TF_VAR_vsphere_password",
        "TF_VAR_vsphere_username",
        "ARM_ACCESS_KEY"
    )
}

# -- Print a warning message --
function Warn {
    Param (
        [Parameter(Mandatory)]$message
    )
    if (-not $Vars.no_warn) {
        Write-Host "[WARNING] $($message)" -BackgroundColor Yellow -ForegroundColor Black
    }
}

# -- Clean sensitive environment variables --
function Clean-Environment {
    if (-not $Vars.no_clean) {
        $Vars.Credentials = $null
        foreach ($v in $Vars.environment_variables) {
            $path = "Env:$v"
            if (Test-Path $path) {
                Remove-Item $path
            }
        }
    }
    else {
        Warn "Sensitive environment variables not removed from the current session!"
    }
}

# -- Determine if the instances tracked by Terraform actually exist in the real infrastructure --
function Fix-StateMismatch {
    <#
    Look, this gets complicated. In essence, terraform expects that the infrastructure it manages (i.e. the class VMs) is managed ONLY by terraform.
    It tracks this infrastructure in the state file. If you look in providers.tf, you can see that we're using a remote backend. This means the state file is stored in a central location (Azure).
    If you manually delete any of this infrastructure (folders, VMs, snapshots), the state file is not aware of that action since it wasn't initiated by terraform.
    You can see how this would cause a problem. This function checks to make sure no such problems exist before continuing. If they do exist, it fixes it.

    Don't read too much into the regular expression stuff - PowerShell doesn't play nice with string literals. 
    #>
    Param (
        [Parameter(Mandatory)][string]$Target
    )
    function Mismatch-Logic {
        Param (
            [string]$output
        )

        $error_patterns = @("ServerFaultCode: The object '.*?' has already been deleted", "Error while getting the VirtualMachine :")

        foreach ($e in $error_patterns) {
            if ($output -match $e) {
                if ($output -match 'with .+\[".*?"\]') {
                    $key = ($matches[0] -replace "with ", "") -replace '"', '\"'
                }
                Modify-TerraformState -Action "rm" -Key $key
                return $true
            }
        }
    }

    function Find-Mismatch {
        Param (
            [string]$Target
        )
        do {
            $out = terraform plan --var-file="$HOME\COI\TerraformVars\vars.tfvars" -no-color -target="module.$Target" 2>&1 | Out-String
            $mismatch = (Mismatch-Logic -output $out)
        } while ($mismatch)
    }

    if ($Target -eq "all") {
        foreach($t in @("folders","virtual_machines","snapshots")) {
            write-host "[POWERSHELL] Checking for state mismatch on target module $t" -ForegroundColor White
            Find-Mismatch -Target $t
        }
    }
    else {
        Find-Mismatch -Target $Target
    }
}

# -- Gracefully exit the program; remove environment variables and return to starting directory --
function Terminate-Program {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)]$message,
        $err = ""
    )

    Set-Location $Vars.current_dir
    Write-Host "[FATAL] $($message)" -BackgroundColor Red -ForegroundColor Black

    if ($PSCmdlet.MyInvocation.BoundParameters["Verbose"] -and $err) {
        Write-Host "VERBOSE: $($err)" -ForegroundColor Yellow
    }

    Clean-Environment
    Start-Sleep 3
    exit(1)
}

# -- Check and attempt to automatically acquire software/environment dependencies --
function Verify-Setup {
    <#
    The other functions in this script require the following prerequisites to be met:
    - Terraform installed
    - Git installed
    - A local, up-to-date git repository containing the required Terraform files
    - The Az.Storage and Az.Accounts PowerShell modules
    - The access key for the Azure storage blob terraformconfigdata stored in an environment variable

    This function will check these dependencies and acquire them if they are not met. 
    #>

    [CmdletBinding()]
    Param ()
    $VerbosePreference = 'SilentlyContinue'
    $Verbose = ([bool]$PSCmdlet.MyInvocation.BoundParameters["Verbose"])

    Write-Host "-------- Checking prerequisites... --------"

    function Install-Terraform {
        $download_path = "$($HOME)\Downloads\terraform.zip"
        $extract_path = "$($HOME)\COI\TerraformInstall"

        if (!(Test-Path $extract_path)) {
            New-Item -ItemType Directory -Path $extract_path -Force | Out-Null
        }

        try {
            # Download the terraform zip file
            Write-Host "    Downloading..."
            Invoke-WebRequest -URI "https://releases.hashicorp.com/terraform/1.10.4/terraform_1.10.4_windows_amd64.zip" -OutFile $download_path -Verbose:$false
            # Extract the contents
            Write-Host "    Extracting contents..."
            Expand-Archive -Path $download_path -DestinationPath $extract_path -Force
        }
        catch {
            Remove-Item -Path $download_path -Force
            Remove-Item -Path $extract_path -Force
            Terminate-Program -Message "An error occured while downloading Terraform. Install canceled. You may need to install it manually." -Verbose:$Verbose -err $_
        }

        # Get what is currently in the PATH variable for user scope
        $path = [System.Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::User)
        if (!($path -match "Terraform")) {
            Write-Host "    Setting path variable..."
            # Permanently change the PATH variable for the user scope if Terraform isn't already there. This changes the PATH variable by a registry update.
            [System.Environment]::SetEnvironmentVariable("Path", "$path$extract_path", [System.EnvironmentVariableTarget]::User)
            # The $env:PATH variable stores the current processes' environment variables, and it's what is actually important here. These environment variables are inherited from the calling process (explorer.exe)
            # Since we just changed the PATH variable via the registry, it is likely not updated in the current process, so we simply append the Terraform install location to it.
            # However, sometimes the current process does refresh its environment variables by listening for registry changes, in which case, it will become aware of the updated PATH variable. So we check if that's the case first.
            # Any other processes started by this user will include the full PATH since we permanently changed it earlier, and this if block won't even be triggered.
            if (!($env:PATH -match ([regex]::Escape($extract_path)))) {
                $env:PATH += $extract_path
            }
        }
        Remove-Item -Path $download_path -Force
    }

    function Install-Git {
        $download_path = "$($env:TEMP)\git.exe"
        $install_path = "C:\Program Files\Git"
        $env_path = "C:\Program Files\Git\cmd"

        try {
            Write-Host "    Downloading..."
            Invoke-WebRequest -URI "https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/Git-2.47.1-64-bit.exe" -OutFile $download_path -Verbose:$false
            $git_args = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=`"$install_path`""
            Write-Host "    Installing..."
            Start-Process -FilePath $download_path -ArgumentList $git_args -Wait
        }
        catch {
            Remove-Item -Path $download_path -Force
            Terminate-Program -Message "An error occured while downloading Git. Install canceled. You may need to install it manually." -Verbose:$Verbose -err $_
        }

        # Git also requires an update to the PATH variable. It does so automatically when it gets installed, but like Terraform, the current process might not be aware of the updated PATH variable.
        if (!($env:PATH -match ([regex]::Escape($env_path)))) {
            Write-Host "    Setting path variable..."
            $env:PATH += ";$($env_path)"
        }
        Remove-Item -Path $download_path -Force
    }

    function Clone-Repo {
		Param(
			[Parameter(Mandatory)]$full_clone
		)
		
        Write-Host "    Pulling contents..."
		if ($full_clone) {
			# If the expected location does not exist, create it and clone the repository

			New-Item -ItemType Directory -Path $Vars.local_repo | Out-Null
			Set-Location $Vars.local_repo

			git init | Out-Null
            git config --global --add safe.directory $Vars.repo_url
			git remote add origin $Vars.repo_url
			git branch -m "main"
		} 
		else {
			Set-Location $Vars.local_repo
		}

        $result = git pull origin main

        # This method is more reliable than using $? to see if the last git command failed for a number of reasons that have to do with where git sends output.
        # Sometimes it sends output to STDERR even when nothing fatal occured, and something it sends fatal errors to STDOUT. Quite unpredictable. 
        if (-not $LASTEXITCODE -eq 0) {
            Terminate-Program -message "Failed to pull from $($Vars.repo_url) with operation full_clone $($full_clone)" -Verbose:$Verbose -err $result
        }
    }

    function Check-Repo {
        # If the local repository wasn't found and needs to be cloned, this function gets called before Clone-Repo which will cause this command to error
        # We can't just make the directory if it doesn't exist because it needs to be initialized by git before running any git commands, which the Clone-Repo function handles.
        try {
            Set-Location $Vars.local_repo -ErrorAction Stop
        }   
        catch {
            return $false
        }
        
        git branch --set-upstream-to=origin/main | Out-Null
        $result = git fetch origin
        if ($LASTEXITCODE -ne 0) {
            Terminate-Program -message "An error occurred when fetching from $($Vars.repo_url). Unable to ensure your local repository is up to date." -Verbose:$Verbose -err $result
        } 
        
        $status = (git status)

        if ($status -match "Your branch is behind") {
            return $false
        }
        return $true
    }

    function Install-RequiredModules {
        try {
            # This will also install the Az.Accounts module
            Write-Host "    Installing..."
            Install-Module -Name "Az.Storage" -AllowClobber -Force -Scope CurrentUser -WarningAction Stop -ErrorAction Stop -Verbose:$false
        }
        catch {
            Terminate-Program -Message "Failed to install Az.Storage module. You may need to troubleshoot and manually install it by running: Install-Module -Name Az.Storage -AllowClobber -Scope CurrentUser" -Verbose:$Verbose -err $_
        }
    }

    function Get-ARMAccessKey {
        $subscription_id = "95b1fee6-9ef4-4b75-aff6-8c72fda81f29"
        try {
            Update-AzConfig -DefaultSubscriptionForLogin $subscription_id | Out-Null
            Write-Host "    Connecting to Azure..."
            Connect-AzAccount -Credential $Vars.Credentials -WarningAction Ignore -ErrorAction Stop | Out-Null
    
            Write-Host "    Obtaining storage account key..."
            $access_key = (Get-AzStorageAccountKey -ResourceGroupName "terraform-config-data" -Name "terraformconfigdata")[0].value
            $env:ARM_ACCESS_KEY = $access_key
        }
        catch {
            Terminate-Program -Message "An error ocurred when reading from Azure subscription Prod_NKU. Make sure you have the correct permissions to read the resource group terraform-config-data." -Verbose:$Verbose -err $_
        }
    }

    # Git sends everything to STDERR which makes it very hard to capture the output non-interactively with PowerShell. This environment variable tells Git to redirect STDERR output to STDOUT so it can be parsed easier.
    $env:GIT_REDIRECT_STDERR = "2>&1"
    $dependencies = @(
        @{
            Name = "[1] Terraform"
            Check = {Get-Command terraform -CommandType Application -ErrorAction SilentlyContinue}
            Action = {Install-Terraform}
        },
        @{
            Name = "[2] Git"
            Check = {Get-Command git -ErrorAction SilentlyContinue}
            Action = {Install-Git}
        },
        @{
            Name = "[3] Local Repo"
            Check = {(Test-Path $Vars.local_repo)}
            Action = {Clone-Repo -full_clone:$true}
        },
        @{
            Name = "[4] Up To Date Repo"
            Check = {(Check-Repo) -and (Test-Path $Vars.local_repo)}
            Action = {Clone-Repo -full_clone:$false}
        },
        @{
            Name = "[5] Az.Storage Module"
            Check = {Get-InstalledModule -Name "Az.Storage" -ErrorAction SilentlyContinue}
            Action = {Install-RequiredModules}
        },
        @{
            Name = "[6] Azure Access Key"
            Check = {[bool]$env:ARM_ACCESS_KEY}
            Action = {Get-ARMAccessKey}
        }
    )

    $not_found = @()

    foreach ($d in $dependencies) {
		$check = $d.Check.Invoke('SilentlyContinue')

        Write-Host "$($d.name)" -NoNewline -ForegroundColor White
        if (!$check) {
            $not_found += $d
            Write-Host " Not found, acquiring..." -ForegroundColor Red
			($d.Action).Invoke()
        }
        else {
            Write-Host " Found $([char]0x2714)" -ForegroundColor Green
        }
    }

    if ($not_found) {
        Write-Host "`nThe following dependencies were automatically acquired:" -BackgroundColor Yellow -ForegroundColor Black
        foreach ($d in $not_found) {
            Write-Host $d.Name -ForegroundColor White
        }
    }
    
    Set-Location $Vars.local_repo
    Write-Host "-------- Prerequisites OK, proceeding... --------"
}

# -- EXPORTED FUNCTIONS -- 

# -- Return a list of students and the professor for a given class --
function Get-ClassRoster {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)][string]$Class,
        [string]$Path = $null
    )

    $Verbose = ([bool]$PSCmdlet.MyInvocation.BoundParameters["Verbose"])

    if (-not $Path) {
        $Path = "\\hh.nku.edu\departments$\College of Informatics\Dean's Office\Current Dean COI\Griffin Hall\Class Lists\Auto Generated Informatics Roster - Class.csv"
    }

    try {
        $csv = Import-CSV -Path $Path
		$dept, $sec = $Class.Split(" ")
    
		$students = $csv | ? {$_.Department -match $dept -and $_.Section -match $sec} | Select -ExpandProperty Student_ID
		$professor = $csv | ? {$_.Department -match $dept -and $_.Section -match $sec} | Select -ExpandProperty Instructor | Get-Unique
		
		if ((-not $students) -or (-not $professor)) {
			throw "Empty student or professor list returned for $($Class). Make sure it is correct."
		}
    }
    catch {
        Terminate-Program -message "Unable to import class roster list to find $($Class)." -Verbose:$Verbose -err $_
    }

	return $students, $professor
}

# -- Generate the necessary variable file for Terraform to clone class VMs --
function Generate-TFVariablesList {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)]$Class,
        [string]$customRosterPath = $null
    )

    $classList = (Get-ClassRoster -Class $Class -Path $customRosterPath)
    $tfvars_path = "$HOME\COI\TerraformVars"
    $varsFile = "$tfvars_path\vars.tfvars"

    if (-not (Test-Path -Path $tfvars_path)) {
        New-Item -ItemType Directory -Path $tfvars_path -Force | Out-Null
    }
    elseif (Test-Path -Path $varsFile){
        Warn "Existing vars.tfvars file being replaced"
        Remove-Item -Path $varsFile -Force | Out-Null
    }

    $students, $professor = $classList[0], $classList[1]

    $student_list = ($students | % {"`"$_`""}) -join ","
    $student_content = "student_list = [$($student_list)]"

    $professor_list = "`"$professor`""
    $professor_content = "professor_list = [$($professor_list)]"

    $folder = "folder = `"/Coivcenter_Test/terraform_test`""

    Set-Content -Path $varsFile -Value "$student_content`n$professor_content`n$folder"
}

# -- Perform modifications to the terraform state file --
function Modify-TerraformState {
    <#
    Terraform expects that every change to the infrastructure its modifying happens through terraform and only through terraform.
    When you run terraform apply for the first time, it notes the infrastructure it's acting upon and tracks it in a file known as the state file.
    Unfortunately, we can't guarantee that changes only happen through terraform. VMs, folders, and snapshots may have a good reason to be manually deleted.
    If this happens, the "real" infrastructure no longer exists, but terraform isn't aware of this because it still tracks the infrastructure in the state file.
    The fix for this is to remove the tracked instances from the state file. The terraform rm command does exactly that.

    This function serves as a wrapper for terraform rm, making it easier to use.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ActionOnly')]
    Param (
        [Parameter(Position = 0, ParameterSetName = 'ActionOnly', Mandatory = $true)]
        [Parameter(Position = 0, ParameterSetName = 'ActionWithKey', Mandatory = $true)][string]$Action,
        [Parameter(Position = 1, ParameterSetName = 'ActionWithKey', Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Key
    )

    $Verbose = ([bool]$PSCmdlet.MyInvocation.BoundParameters["Verbose"])

    Set-Location $Vars.local_repo
    if ($PSCmdlet.ParameterSetName -eq 'ActionOnly') {
        if ($Action -eq "list") {
            terraform state $Action
        }
        else {
            Terminate-Program -Message "If a Key is not provided for Modify-TerraformState, the only acceptable action is 'list'"
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'ActionWithKey') {
        if ($Action -match "rm|remove") {
            Write-Host "The following entries in terraform.tfstate will be removed (This can NOT be undone): $key" -ForegroundColor Yellow
            $continue = Read-Host "Continue? Y/N"

            if ($continue -eq "Y") {
                terraform state rm $key
            }
            else {
                Terminate-Program -message "The necessary changes to the terraform state file were denied." -Verbose:$Verbose -err "The following entries from the state file weren't removed: $to_modify"
            }
        }
    }
}

# -- Terraform interface --
function Exec-Plan {
    <#
    This function uses cmdletbinding, which makes it an "advanced function". It basically means it can use "common" PowerShell parameters such as Verbose and ErrorAction.
    The other parameters are:

    Class - The full course code including section for the class being targeted by this terraform run
    Target - Which terraform module to target on the apply. In other words, are we creating folders, virtual machines, snapshots, or attempting all 3?
    customRosterPath - File location of a custom roster, if needed
    Parallelism - How many concurrent cloning operations Terraform will run. Default is 10.
    MaxRetries - How many times the script attempts to retry a terraform apply if state mismatches are detected.
    NoClean - Switch parameter that if set will prevent the script from cleaning sensitive environment variables. This is useful for when you plan to run the script multiple times in the same session. It is recommended to leave this off.
    SkipDependencyCheck - Switch parameter that if set will prevent the script from checking the necessary dependencies. If you're having trouble with it trying to automatically acquire something and failing, you may need to use this.
    SuppressWarnings - Switch parameter that if set will prevent any custom warnings from being printed.
    PlanOnly - Switch parameter that tells the script to not attempt to apply the terraform configuration, only plan it for review.

    Verbose - Switch parameter that will include more information if a fatal error occurs.
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)][string]$Class,
        [string][ValidateSet("folders","virtual_machines","snapshots","all")]$Target = "all",
        [string]$customRosterPath = $null,
        [int]$Parallelism = 10,
        [int]$MaxRetries = 3,
        [Switch]$NoClean,
        [Switch]$SkipDependencyCheck,
        [Switch]$SuppressWarnings,
        [Switch]$PlanOnly
    )

    $Verbose = ([bool]$PSCmdlet.MyInvocation.BoundParameters["Verbose"])
    $Vars.no_clean = ([bool]$NoClean)
    $Vars.no_warn = ([bool]$SuppressWarnings)

    if ((-not $env:TF_VAR_vsphere_username) -or (-not $env:TF_VAR_vsphere_password) -or (-not $env:ARM_ACCESS_KEY)) {
        # The default behavior of the script is to clear the environment variables storing sensitive information after each run. The NoClean flag will prevent this.
        # If the environment variables aren't cleared, there's really no need to prompt again since they persist in the current PowerShell session.
        if (-not $Vars.Credentials) {
            $Vars.Credentials = (Get-Credential -Message "Enter your credentials for an account with privileges on vSphere and Azure:" -User "da_$($env:USERNAME)@nku.edu")
        }
        $env:TF_VAR_vsphere_username = $Vars.Credentials.UserName
        $env:TF_VAR_vsphere_password = $Vars.Credentials.GetNetworkCredential().Password
    }
    else {
        Warn "Skipping credential check. The necessary environment variables already exist. To change this, restart the terminal and do not include the -NoClean switch on your next run."
    }
    
    if ($SkipDependencyCheck) {
        Warn "Skipping dependency check"
        if (-not (Test-Path $Vars.local_repo)) {
            Terminate-Program -message "Unable to properly initialize Terraform. Please try again without the -SkipDependencyCheck flag."
        }
    }
    else {
        Verify-Setup -ErrorAction SilentlyContinue -Verbose:$Verbose
    }
    Set-Location $Vars.local_repo

    Generate-TFVariablesList -Class $Class -customRosterPath $customRosterPath
    terraform init

    Fix-StateMismatch -Target $Target

    if ($Target -eq "all") {
        foreach ($t in @("folders","virtual_machines","snapshots")) {
            if ($t -eq "snapshots") {
                Fix-StateMismatch -Target "snapshots"
            }
            terraform apply -var-file="../TerraformVars/vars.tfvars" -target="module.$t"
        }
    }
    
    Clean-Environment
    Set-Location $Vars.current_dir
}
