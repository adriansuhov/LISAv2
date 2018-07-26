# Developing LISAv2

## Coding style

### Bash
Run shellcheck for every BASH/SH script. Shellcheck can be installed on any nix system and there are off-the-shelf binaries for Windows.

shellcheck installation guide: https://github.com/koalaman/shellcheck#installing

### PowerShell

Run PSScriptAnalyzer and PowerShell-Beautifier for every PowerShell .ps1 and .psm1 script.

PSScriptAnalyzer: https://github.com/PowerShell/PSScriptAnalyzer

PowerShell-Beautifier: https://github.com/DTW-DanWard/PowerShell-Beautifier

On top of that, make sure you respect on a best effort basis the following guidelines: https://github.com/ader1990/PowerShell-Guidelines
### Python

Run pep8 and flake8 for every Python script.

Pep8: https://pypi.org/project/pep8/

Flake8: http://flake8.pycqa.org/en/latest/

## Unit tests

For PowerShell, unit tests can be written using Pester.

Pester how to's: https://github.com/pester/Pester

