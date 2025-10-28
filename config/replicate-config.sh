# example ${1} = "7.3.0", ${2} = "81180", ${3} = "7.3.1", ${4} = "86003"

for m in `cat platform73`
do 
echo "Working on $m"
#cp -rp $m/${1}-${2} $m/${3}-${4}
sed -i "s/${1}/${3}/g" $m/${3}-${4}/config.json
sed -i "s/${2}/${4}/g" $m/${3}-${4}/config.json
done
