BeforeAll {
    . "$PSScriptRoot/../compact-wsl.ps1"
    $script:DiskPath = Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'
    $script:DataPath = Join-Path $env:LOCALAPPDATA 'Docker\wsl\data\ext4.vhdx'
}

Describe 'Get-DockerDisk' {
    It 'returns nothing when Docker Desktop is not installed' {
        Mock Test-Path { $false }
        Get-DockerDisk | Should -BeNullOrEmpty
    }

    It 'finds the docker_data.vhdx layout' {
        Mock Test-Path { $LiteralPath -eq $script:DiskPath }
        $found = @(Get-DockerDisk)
        $found.Count | Should -Be 1
        $found[0].Name | Should -Be 'docker-desktop'
        $found[0].Vhdx | Should -Be $script:DiskPath
    }

    It 'finds the newer data\ext4.vhdx layout' {
        Mock Test-Path { $LiteralPath -eq $script:DataPath }
        $found = @(Get-DockerDisk)
        $found.Count | Should -Be 1
        $found[0].Vhdx | Should -Be $script:DataPath
    }

    It 'returns both when both layouts are present' {
        Mock Test-Path { $true }
        @(Get-DockerDisk).Count | Should -Be 2
    }
}
