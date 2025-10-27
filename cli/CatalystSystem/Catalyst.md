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
- values such as in --flag=8 will be supported even without the equal sign , therefore allowing --flag8 and -f8 too. Could also be -ftrue or -fno-option which translate to -f=true and -f=no-option
- flags may also support the windows convention of / as in /i or /include representing -i or --include respectively



### Parse Logic 

Using goto and labels for faster flag recognizing times , start with - , -- , / jump labels , and then branch. 