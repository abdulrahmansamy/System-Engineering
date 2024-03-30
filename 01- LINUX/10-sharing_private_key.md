
## Share Private Key In Mac

### Pack it in zip archive with password
```
zip -er PRIVATE_KEY_ARCHIVE.zip PRIVATE_KEY_DIR/

```

### Check the archive contents
```
unzip -l PRIVATE_KEY_ARCHIVE.zip 

```

### Delete undesired files

```
zip -d MOS_EDR_CREDS.zip PRIVATE_KEY_DIR/.DS_Store PRIVATE_KEY_DIR/other_files
```