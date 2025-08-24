#!/bin/bash



options=("Option 1" "Option 2" "Option 3" "Quit")

select opt in "${options[@]}"
do
    case $opt in
        "Option 1")
            echo "You chose Option 1"
            ;;
        "Option 2")
            echo "You chose Option 2"
            ;;
        "Option 3")
            echo "You chose Option 3"
            ;;
        "Quit")
            break
            ;;
        *) echo "Invalid option $REPLY";;
    esac
done

# select an item within a list
for x in 1 2 3 4 
do 
echo $x 
done



for x in one two three
do
echo $x
done

options=("Option 1" "Option 2" "Option 3")
select ITEM in "${options[@]}"
do
    echo $ITEM
done