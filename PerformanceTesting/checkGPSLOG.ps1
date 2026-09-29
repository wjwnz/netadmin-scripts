Get-ChildItem "C:\Program Files\Palo Alto Networks\GlobalProtect" -Filter *.log |
ForEach-Object {
    Write-Host "`n===== $($_.Name) ====="

    Select-String `
        -Path $_.FullName `
        -Pattern "CA-AB-","NZ-","AU-","US-","<description>","gateway-list" `
        -SimpleMatch |
    Select-Object -First 5
}