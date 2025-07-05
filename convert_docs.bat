@echo off
REM Batch script to convert JSON API documentation to MDX files for Starlight

echo Converting JSON to MDX files...

REM Check if Python is available
python --version >nul 2>&1
if errorlevel 1 (
    echo Python is not installed or not in PATH
    exit /b 1
)

REM Create output directory if it doesn't exist
if not exist "docs" mkdir docs

REM Convert the string slice API
if exist "lib-helix\docs\json\std-string-slice-api.json" (
    echo Converting std-string-slice-api.json...
    python json_to_mdx_converter.py "lib-helix\docs\json\std-string-slice-api.json" --output docs
) else (
    echo Warning: std-string-slice-api.json not found
)

REM You can add more JSON files here as needed
REM python json_to_mdx_converter.py "path\to\other\api.json" --output docs

echo Conversion complete! Check the 'docs' directory for MDX files.
pause
