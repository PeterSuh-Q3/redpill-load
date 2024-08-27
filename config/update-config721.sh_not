for model in `cat models.72`
do 
echo "modify config.json on $model"
value=`grep $model _common/kernel-bs-fb-patch-for-all/files-chksum | grep os.sha256|awk '{print $1}'`
jsonfile=$(jq ".os.sha256=\"$value\"" $model/7.2.1-69057/config.json) 
echo $jsonfile | jq . > $model/7.2.1-69057/config.json

value=`grep $model _common/kernel-bs-fb-patch-for-all/files-chksum | grep files.zlinux.sha256|awk '{print $1}'`
jsonfile=$(jq ".files.zlinux.sha256=\"$value\"" $model/7.2.1-69057/config.json) 
echo $jsonfile | jq . > $model/7.2.1-69057/config.json

value=`grep $model _common/kernel-bs-fb-patch-for-all/files-chksum | grep files.ramdisk.sha256|awk '{print $1}'`
jsonfile=$(jq ".files.ramdisk.sha256=\"$value\"" $model/7.2.1-69057/config.json) 
echo $jsonfile | jq . > $model/7.2.1-69057/config.json

value=`grep $model _common/kernel-bs-fb-patch-for-all/files-chksum | grep files.vmlinux.sha256|awk '{print $1}'`
jsonfile=$(jq ".files.vmlinux.sha256=\"$value\"" $model/7.2.1-69057/config.json) 
echo $jsonfile | jq . > $model/7.2.1-69057/config.json

sed -i 's#release/7.2/69057-1#release/7.2.1/69057#g' $model/7.2.1-69057/config.json
#sed -i 's#@@@COMMON@@@/ramdisk-001#@@@COMMON@@@/v7.2.0/ramdisk-001#g' $model/7.2.1-69057/config.json

done 

for model in `cat models.72`
do 
echo "rename bsp file on $model"
remodel=$(echo "$model" | sed 's/DS//' | sed 's/RS//' | sed 's/+/p/' | sed 's/DVA/dva/' | sed 's/FS/fs/' | sed 's/SA/sa/' )
echo "$remodel"
#cp _common/kernel-bs-fb-patch-for-all/zImage-001-${model}-69057-ramdisk-and-flag-NOP.bsp $model/7.2.1-69057/zImage-001-${remodel}-69057-ramdisk-and-flag-NOP.bsp

done
