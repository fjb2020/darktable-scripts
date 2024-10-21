# darktable_scripts

Lua scripts to integrate some third party tools into my Darktable workflow - leaning heavily on scripts written 
by wpferguson https://github.com/wpferguson/extra-dt-lua-scripts 
and ChristianBirzer https://github.com/ChristianBirzer/darktable_extra_scripts

They are dependent on the darktable-org/lua-scripts libraries. They need the darktable-org/lua-scripts respository
installed.  Instructions for installing can be found at https://github.com/darktable-org/lua-scripts/README.md

# 
### DxO_PureRAW

Processes raw images in darktable with DxO_PureRAW (https://www.dxo.com/dxo-pureraw/)

This script adds a new panel to integrate DxO_PureRAW software into darktable to be able to pass or export images to DxO_PureRAW, reimport the result(s) and optionally group the images and optionally copy and add tags to the imported image(s)

When DxO_PureRAW exits, the result files are imported and optionally grouped with the original files.

ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT

DxO_PureRAW (commercial software) - http://www.dxo.com

#### USAGE
Require this script from your main lua file
Specify the location of the DxO_PureRAW executable in Lua Options

Select an image or images for processing with DxO pureRAW
Expand the DxO PureRAW panel (ighttable view) 
    
Select options as required:
- group - group processed image with associated RAW image
- copy tags - copy tags from RAW image to the new  processed image
- copy metadata - copy metadata (title, description, creator, rights) to the new processed image
- new tags - tags to be added to the new processed image

Press "Process with DxO_PureRAW"
Process the images with DxO.PureRAW then save the results
Exit DxO_PureRAW
The resulting image(s) will be imported 

#### CAVEATS
This script was tested using using the following platforms:
- macOS Sonoma 14.5 on Apple Silcon
- Windows 11 ARM running in a VM on Apple Silicon

- darktable 4.8.0 and 4.8.1
- DxO PureRAW 3 and 4

# 
### ZereneStacker

Create focus stack using Zerene Stacker (https://zerenesystems.com/)

This script will add a new panel to integrate Zerene Stacker stacking software into darktable
to be able to pass or export a bunch of images to Zerene Stacker, reimport the result(s) and
optionally group the images and optionally copy and add tags to the imported image(s)

ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT

Zerene Stacker (commercial software) - https://zerenesystems.com/


#### PRIOR TO FIRST RUN
Create an empty folder to be used as the Stacker Staging Folder. 

This folder will be used to store exported images prior to stacking and the output from Zerene Stacker prior to importing to DT.
It will also hold the ZereneBatch.xml batch script file.

WHen Zerene is run using the Batch API (as this script does) it uses a batch script file to tell Zerene Stacker what to do.

More details can be found here https://zerenesystems.com/cms/stacker/docs/batchapi

This lua script assumes that the batch script file is named ZereneBatch.xml and is located in the Stacker Staging Folder.
A sample batch script is included on the web page above which performs simple stacking tasks suitable for this script. Copy this XML
into a new file and save as ZereneBatch.xml in the Staging Folder. Important note that the default output filename pattern of "ZS-OutputImage ZS {method}" should not be altered. This xml should be the only file in the folder (the script may not run if other
files are present). 

Details of how to make more sophisticated batch scipts are on the Zerene web site, and the Zerene Stacker application
can be used to create very complex scripts that can be used instead of the above. 

#### USAGE
Complete the details in darktable global options -> Lua Options:
- Stacker Staging Folder - folder created as above
- Zerene Licence Folder - the folder holding the Zerene Stacker licence file
- Zerene Stacker Java Folder - try
  - macOS : /Applications/ZereneStacker.app/Contents/Resources/Java
  - Windows: C:\Program Files\ZereneStacker

Select two or more images
Expand the zerene stacker panel
- group: If checked, the selected source images and the imported results are grouped together and the first result image
  is set as group leader
- copy tags: If checked, all tags from all source images are copied to the resulting image
- new tags: Enter a comma seperated list of tags that shall be added to the resulting image on import.
- stack with Zerene Stacker: Press this button to start export of tifs and then start Zerene Stacker application

The selected images will be exported to .tif files in the Stacker Staging Folder
Zerene will launch and process the images per the ZereneBatch.xml script
Once the batch processing is complete a dialog will pop - click OK to acknowledge.
Zerene Stacker will stay open to allow retouching - ensure the output files(s) are resaved if changes are made
Close Zerene Stacker after saving to start the import of the resulting image(s). 

The stacked images will be moved to folder of the first input files and imported to Darktable
More than one image (e.g. different stacking settings) can be saved and all of them will be imported after closing zerene stacker

#### NOTE
The script uses the luafilesystem library (https://lunarmodules.github.io/luafilesystem/index.html, installed via luarocks) if it is installed.
If it is not available the script will still work but will fail to import the stacked images if the default output filenames from Zerene Stacker are altered.

#### CAVEATS
This script was tested using using the following platforms:
- macOS Sonoma 14.5 on Apple Silcon
- Windows 11 ARM running in a VM on Apple Silicon

- darktable 4.8.0 and 4.8.1
- Zerene Stacker Version 1.04 Build T2023-06-11-1120

- It does not currently work on Linux as the scrit does not yet build a launch command for Zerene Stacker for Linux (this is ToDo)
