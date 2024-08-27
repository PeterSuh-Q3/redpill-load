# example ${1} = "7.2.0", ${2} = "64570", ${3} = "7.2.1", ${4} = "69057"

for m in `cat models.72`
do 
echo "Working on $m"
cp -rp $m/${1}-${2} $m/${3}-${4}
sed -i "s/${1}/${2}/g" $m/${3}-${4}/config.json
sed -i "s/${3}/${4}/g" $m/${3}-${4}/config.json
done
