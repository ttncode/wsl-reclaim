@{
    # compact-wsl.ps1 is an interactive console tool: its output is progress for a
    # person watching, deliberately not pipeline data. Write-Output would pollute
    # each function's return value and Write-Information cannot carry colour, so
    # Write-Host is the correct call and this is the only rule excluded.
    ExcludeRules = @('PSAvoidUsingWriteHost')
}
