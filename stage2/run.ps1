param(
 [ValidateSet('create','install','seed','test','explain','drop')] [string]$Action='test',
 [string]$Psql='psql'
)
$ErrorActionPreference='Stop'
function Invoke-Sql([string]$Database,[string]$File) {
 & $Psql -X -v ON_ERROR_STOP=1 -d $Database -f (Join-Path $PSScriptRoot $File)
 if ($LASTEXITCODE -ne 0) { throw "psql failed: $File" }
}
switch ($Action) {
 create { Invoke-Sql 'postgres' 'sql/00_create_database.sql' }
 install { Invoke-Sql 'clinic_coursework' 'sql/install.sql' }
 seed { Invoke-Sql 'clinic_coursework' 'sql/05_seed.sql' }
 test {
  Invoke-Sql 'clinic_coursework' 'tests/integrity.sql'
  Invoke-Sql 'clinic_coursework' 'tests/lifecycle.sql'
 }
 explain { Invoke-Sql 'clinic_coursework' 'sql/06_explain.sql' }
 drop { Invoke-Sql 'postgres' 'sql/99_drop_database.sql' }
}
