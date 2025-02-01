## HuginPanorama

 ================================================================

Create panorama using Hugin tools 

When Hugin completes, the result is imported and optionally grouped with the original files.

ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT

Hugin and associated commandline tools - https://sourceforge.net/projects/hugin/

ExifTool by Phil Harvey - https://exiftool.org

OPTIONAL ADDITIONAL SOFTWARE USED BY SCRIPT IF INSTALLED

LuaFileSystem - https://luarocks.org/modules/hisham/luafilesystem


### USAGE

Require this script from your main lua file

#### PRIOR TO FIRST RUN
  Create an empty folder to be used as the Hugin  Staging Folder. 
  This folder will be used to store exported images prior to stitching as well as various files created by Hugin and tools.
  THis folder should be emptied by the script on completion.

  Specify the following in Lua options (values included are those from my systems and may be different on yours)

    hugin_tools directory
      windows  c:\Program Files\Hugin\bin
      ubuntu   /usr/bin
      macOS   /Applications/Hugin/tools_mac

    Hugin executable
      windows  c:\Program Files\Hugin\bin\hugin.exe
      ubuntu   /usr/bin/hugin
      macOS 
        Check https://bitbucket.org/Dannephoto/hugin/ for a recent macOS build 
        /Applications/Hugin/Hugin.app/Contents/MacOS/Hugin
          (to set in Lua options, open a finder window, locate and right click on 
          /Applications/Hugin/Hugin.app, click Show Package Contents, navigate 
          to Contents/MacOS and drag Hugin to the Hugin executable box)
    
    Hugin Staging Folder
        A directory to be used to store interim files created by Hugin. Should 
        be empty when this script isn't running

    exiftool executable
      windows 
        may be bundled with Hugin, so try c:\Program Files\Hugin\bin\exiftool.exe
        if downloaded and installed from https://exiftool.org/ then whereever you 
        installed it
        
      ubuntu 
        sudo apt install exiftool
        location: /usr/bin/exiftool

      macOS
        Download package from https://exiftool.org
        location: /usr/local/bin/exiftool
        

    
#### Normal Operation

Expand the Hugin Panorama module in lighttable
  
Select two or more images

Options are as follows:
  - use Hugin GUI - run hugin via GUI or transparently in the background                    
  - group - panorama will be grouped with source images an placed on top of the group
  - copy metadata - metadata from the first source image (per the metadata editor panel) will be applied to the panorama image
  - copy tags - copy keyword tags from first source image to  the panorama image
  - Copy EXIF - exiftool will be used to copy all EXIF from first source image to panorama image
  - new tags - a comma seperated list of tags that to be added to the panorama image

Select the series images to be merged into a panorama 

Press "Process with Hugin" to create the panorama
tif versions of the selected images will be exported to the staging folder

If the GUI option is selected, Hugin GUI will open with the selected images loaded ready for aligning and stitching
  As part of the panorama creation process you will be asked to save two files
  - if the default filenames are changed then the script will not be able to automatically import the resultant panorama, or clear the staging folder
  - close Hugin to trigger the import of the resultant panorama into darktable

If unchecked, hugin tools will run in the background to create a panorama based on default settings
  - progress updates are displayed in the message area
  - if images that don't overlap are selected you will get unpredicatable results
  - the resultant panorama will be imported into darktable
  
### TROUBLESHOOTING
Check the staging folder is empty
Check the various hugin executables and folders are present and executable
Ensure selected images are part of a contiguous panorama


### WARNING
This script was tested on the following platforms:
  - darktable 5.0.0 on:
    - macOS on Apple Silcon
    - ubuntu 24.04
    - Windows 11 ARM running in a VM on Apple Silicon

### Notes
This script originally used hugin-assistant to perform the final stitching step when run without a GUI, but for some reason this step failed on my Mac unless darktable was launched via a command window (e.g. /darktable -d lua). I found a few others who had encountered a similar issue but couldn't find a fix. So instead, for the non-GUI option I broke the panorama creation down in to the stages identified at https://wiki.panotools.org/Panorama_scripting_in_a_nutshell - i.e.
  
      pto_gen -o project.pto inputfile1, inputfile2, ...
      cpfind -o project.pto --multirow --celeste project.pto
      cpclean -o project.pto project.pto
      linefind -o project.pto project.pto
      autooptimiser -a -m -l -s -o project.pto project.pto
      pano_modify --canvas=AUTO --crop=AUTO -o project.pto project.pto
      nona  -m TIFF_m -o project project.pto
      enblend -o project.tif project0000.tif project0001.tif project0002.tif project003.tif

