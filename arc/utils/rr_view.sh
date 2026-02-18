#!/bin/bash

#-f format | -l | -r | -s | -x] [-t timefmt]
FILE="source/parser/ast/kairo.ebnf"
COMMAND="java -jar temp/utils/railroad/rr.war -width:1500 -html $FILE"
VIEW_COMMAND="open ./index.html"
LAST_MODIFIED=$(stat -f "%m" "$FILE")

$COMMAND > index.html
$VIEW_COMMAND

while true; do
    CURRENT_MODIFIED=$(stat -f "%m" "$FILE")
    if [ "$CURRENT_MODIFIED" != "$LAST_MODIFIED" ]; then
        $COMMAND > index.html
        echo "file changed"
        LAST_MODIFIED=$CURRENT_MODIFIED
    fi
    sleep 1
done
