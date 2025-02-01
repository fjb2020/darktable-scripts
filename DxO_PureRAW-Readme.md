### DxO_PureRAW

Processes raw images in darktable with DxO_PureRAW (https://www.dxo.com/dxo-pureraw/)

This script adds a new panel to integrate DxO_PureRAW software into darktable to be able to pass or export images to DxO_PureRAW, reimport the result(s) and optionally group the images and optionally copy and add tags and metadata to the imported image(s)

ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT

DxO_PureRAW version 3 or 4 (4.7+) (commercial software - http://www.dxo.com)

OPTIONAL ADDITIONAL SOFTWARE USED BY SCRIPT IF INSTALLED

LuaFileSystem - https://luarocks.org/modules/hisham/luafilesystem

#### USAGE
Require this script from your main lua file

Prior to first run, specify the following in Lua options:
    
    DxO_pureRAW executable
        the default installation locations are as follows but set them as 
        appropriate on your system:
    
        windows 
            version 3 c:\Program Files\DxO\DxO PureRAW 3\PureRawv3.exe 
            version 4 c:\Program Files\DxO\DxO PureRAW 4\PureRawv4.exe 
 
        macOS
            version 3 /Applications/DxO PureRAW 3
            version 4 /Applications/DxO PureRAW 4

    DxO 4 Staging Folder (ignore this setting if you have version 3)
        A folder to be used by pureRAW 4 for temporary storage 
        of the processed files
    
    DxO 4 Timeout
        Set the maximum time in minutes the script should wait for pureRAW 4
        to process an image. If not set a default of 2 minutes seconds will be used. 
        A range of 0 to 30 is allowed. 
        See notes below for an explanation of this parameter 



Select an image or images for processing with DxO pureRAW
Expand the DxO PureRAW panel (ighttable view) 
    
Select options as required:
- group - group processed image with associated RAW image
- copy tags - copy tags from RAW image to the new  processed image
- copy metadata - copy metadata (title, description, creator, rights) to the new processed image
- new tag - tags to be added to the new processed image
         
Press "Process with DxO_PureRAW"
    
Process Settings should be as follows:
    
    Version 3
    ========= 
        The only setting that is critical is destination which must be orginal 
        image(s) folder:

        ------------- Destination -------------- 
        x  Original image(s) folder


    Version 4
    =========
        ----------------------------------------
        Corrections 
            set as required
        ----------------------------------------
        Output

        Output Format: Dng 
        (future updates of this script will handle other formats but for now 
        only Dng is supported)
        
        Destination: Staging folder setup earlier
        
        File Renaming: Filename-Processing Method 
        (future updates of this script may allow more flexibility but for now 
        only this format is supported)
        
        Export to application: None
        
        Lightroom Collection Import: ignore
        ----------------------------------------


Once processing has completed, close the 'Export to panel' and close the application. You may wish to clear the lightbox prior to closing. With version 3 the program closes; version 4 stays running minimised in the menubar / system tray

The resulting image(s) will be imported 

#### CAVEATS
This script was tested using using the following platforms:
- macOS Sonoma 14.5 and aove on Apple Silcon
- Windows 11 ARM running in a VM on Apple Silicon

- darktable 4.8.0 and above

- DxO PureRAW 3 and 4.6+

### Notes
Notes on the operation of the script

When first written I was using DxO pureRAW version 3, and it's operation for this version is fairly straigt forward:

Build a command line to run pureRAW with the selected images appended, and tell darktable to run this command, then wait for it to close. Darktable will then locate the new processed images created by pureRAW and import them, optionally grouping, tagging and adding metadate per the options selected.

Version 4 operates quite differently in that it is always running - minimised in the menubar / system tray when not active, or with a visible window when processing images. This change means the approach I used for version 3 doesn't work as the script couldn't detect when image processing had completed. 

The updated script now launches version 4 but doesn't wait for it to close as this won't happen unless closed in the menubar/system tray - instead it waits for the expected processed images to appear in a specified directory. 

Once these images are all present they are moved to the source image folder and imported from there. 

I needed to make sure that the script didn't wait foreever for all the processed images to appear (for e.g. if DxO processing is cancelled, or images are removed from lightbox etc then some of images it is waitng for will never appear) so there is a per image timeout (default 2 minutes). If a processed image doesn't appear in the staging folder within this time the script will import any processed images but leave the rest. This timeout is configurable between 0 and 30 minutes.

A counter of number of images processed and elapsed time is displayed the the bottom of the left panel of lighttable.

A limitation is that I have found no way to stop a script once it's running - so if you start the DxO script and then change you mind, there isn't a way of stopping the script until the specified timeout elapses.

    