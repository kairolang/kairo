# Catalyst

**The Catalyst subsystem is the Silica/Helix project's argument parsing library**
(name was chosen based on the projects chemistry themed naming, catalysts influence the outcome of the program)

> **_NOTE_** : This subsystem takes inspiration from LLVM's Option system

CLI arg structure: [system] [flags] [objects]

- the system in our use case is the programming language
- flags aka the catalysts decide how to control the execution of the argument
- objects are just the files that these arguments are carried out on

### flags

List of possible flags supported by the Catalyst system , abiding by ISO standards:

- -f and --flag as commonly used
- values such as in --flag=8 will be supported even without the equal sign , therefore allowing --flag8 and -f8 too. Could also be -ftrue or -foption which translate to -f=true and -f=option
- flags may also support the windows convention of / as in /i or /include representing -i or --include respectively


### Catalyst Execution Flow 

> **_NOTE_** : This will be majorly Macro functions rather than actual ones , so as to reduce function call overhead and maintain scope in the compile script with code injection

- Tokenize into different flags and files
- parse through all flags and include macros for compile time code gen into compile script
- macros set certain values which a compile function will use to tweak the file compilation

