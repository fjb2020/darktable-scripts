--[[
    This file is part of darktable,
    copyright (c) 2022 Christian Birzer
    darktable is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    darktable is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with darktable.  If not, see <http://www.gnu.org/licenses/>.
]]
--[[
ZereneStacker

This script will add a new panel to integrate Zerene Stacker stacking software into darktable
to be able to pass or export a bunch of images to Zerene Stacker, reimport the result(s) and
optionally group the images and optionally copy and add tags to the imported image(s)

ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
you must have Zerene Stacker (commercial software) installed on your system.


PRIOR TO FIRST RUN
Create an empty folder to be used as the Stacker Staging Folder. 
This folder will be used to store exported images prior to stacking and the output from Zerene Stacker prior to importing to DT.
It will also hold the ZereneBatch.xml batch script file.
All images should be removed from this folder once this script completes.
WHen Zerene is run using the Batch API (as this script does) it uses a batch script file to tell Zerene Stacker what to do.
More details can be found here https://zerenesystems.com/cms/stacker/docs/batchapi
This lua script assumes that the batch script file is named ZereneBatch.xml and is located in the Stacker Staging Folder.
A sample batch script is included on the web page above which performs simple stacking tasks suitable for this script. Copy this XML
into a new file and save as ZereneBatch.xml in the Staging Folder. This should be the only file in the folder (the script may not run if other
files are present). Details of how to make more sophisticated batch scipts are on the Zerene web site, and the Zerene Stacker application
can be used to create very complex scripts that can be used instead of the above. 

USAGE
* Choose the executable of the Zerene Stacker software in the preferences / Lua options / Zerene Stacker executable
* Select two or more images
* Expand the zerene stacker panel
* * 'group': If checked, the selected source images and the imported results are grouped together and the first result image
  is set as group leader
* 'copy tags': If checked, all tags from all source images are copied to the resulting image
* 'new tags': Enter a comma seperated list of tags that shall be added to the resulting image on import.
* 'stack with Zerene Stacker': Press this button to start export of tifs and then start Zerene Stacker application
* 
* The selected images will be exported to .tif files in the Stacler Staging Folder
* Zerene will launch and process the images per the ZereneBatch.xml script
* Once the batch processing is complete a dialog will pop - click OK to acknowledge.
* Zerene Stacker will stay open to allow retouching - ensure the output files(s) are resaved if changes are made
* Close Zerene Stacker after saving to start the import of the resulting image(s). 
*
*** NOTE - The script may fail if the default output filenames are altered. ***
*
* The stacked images will be moved to folder of the first input files and imported to Darktable
* More than one image (e.g. different stacking settings) can be saved and all of them will be imported after closing zerene stacker

WARNING
This script was tested on the following platforms:
  - darktable 4.8.1 on:
    - macOS on Apple Silcon
    - Windows 11 ARM running in a VM on Apple Silicon

BUGS, COMMENTS, SUGGESTIONS
    * Send to Fiona Boston, fiona@fbphotography.uk
]]

-- *************************************************
-- Setup and Initialisation
-- *************************************************


local dt = require 'darktable'
local du = require "lib/dtutils"
local df = require 'lib/dtutils.file'
local dsys = require 'lib/dtutils.system'

-- lua libraries installed via luarocks https://github.com/luarocks/luarocks/wiki
-- luafilesystem - https://lunarmodules.github.io/luafilesystem/index.html - file system functions
-- additional validation and output checking is activated if lfs is present
local lfs_loaded,lfs = pcall(require,'lfs')
if lfs_loaded == false then
  dt.print_log("No lfs module")
else
  dt.print_log("lfs module found")
end

-- luaexpat - https://lunarmodules.github.io/luaexpat/index.html - XML Expat parsing
-- not currently used but future enhancement around chcking ZereneBatch.xml may require it
local xml_loaded,lxp = pcall(require,'lxp')
if xml_loaded == true then
  dt.print_log("lxp module found")
else
  dt.print_log("No lxp module")
end


du.check_min_api_version("7.0.0", "ZereneStacker")

local script_data = {}
local temp

script_data.destroy = nil -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again

local GUI = { --GUI Elements Table
  optionwidgets = {
    label_import_options = {},
    group                = {},
    copy_metadata        = {},
    copy_tags            = {},
    add_tags_box         = {},
    add_tags_label       = {},
    add_tags             = {},
  },
  options = {},
  run = {},
}

local mod = 'module_ZereneStacker'
local os_path_seperator = '/'
if dt.configuration.running_os == 'windows' then os_path_seperator = '\\' end

-- find locale directory:
local scriptfile = debug.getinfo( 1, "S" )
local localedir = dt.configuration.config_dir..'/lua/locale/'
if scriptfile ~= nil and scriptfile.source ~= nil then
  local path = scriptfile.source:match( "[^@].*[/\\]" )
  localedir = path..os_path_seperator..'locale'
end
dt.print_log( "localedir: "..localedir )

-- Tell gettext where to find the .mo file translating messages for a particular domain
local gettext = dt.gettext
gettext.bindtextdomain( 'ZereneStacker', localedir )


-- declare a local namespace and a couple of variables we'll need to install the module
local mE = {}
mE.event_registered = false  -- keep track of whether we've added an event callback or not
mE.module_installed = false  -- keep track of whether the module is module_installed

-- *************************************************
-- utility functions
-- *************************************************

local function _(msgid)
  return gettext.dgettext( 'ZereneStacker', msgid )
end

-- *************************
local function export_image( image, exportfilename)
-- export the given single image to tiff (16 bit)

  local curr_image = image.path..os_path_seperator..image.filename

  dt.print_log( "exporting "..curr_image )

  local exporter = dt.new_format("tiff")
  exporter.bpp = 16
  exporter:write_image(image, exportfilename)

  dt.print_log( "exported file: "..exportfilename )
end

-- *************************
local function copy_tags( all_tags, image )
-- add tags on image to all_tags table
  local image_tags = dt.tags.get_tags( image )
    for _,tag in pairs( image_tags ) do
      if string.match( tag.name, 'darktable|' ) == nil then
        dt.print_log( "image: "..image.filename .. "  tag: "..tag.name )
        all_tags[ #all_tags + 1 ] = tag
      end
    end

    dt.print_log( "#all_tags: ".. #all_tags )
end

-- *************************
local function insert_tags( image, tags )
  for _,tag in pairs( tags ) do
    dt.tags.attach(tag, image )
    dt.print_log( 'image: '..image.filename..'  adding tag ', tag.name )
  end
end

-- *************************
--removes spaces from the front and back of passed in text
local function clean_spaces(text)
  text = string.gsub(text,'^%s*','')
  text = string.gsub(text,'%s*$','')
  return text
end

-- *************************
local function add_additional_tags( image )
  local set_tag = GUI.optionwidgets.add_tags.text
  if set_tag ~= nil then -- add additional user-specified tags
    for tag in string.gmatch(set_tag, '[^,]+') do
      tag = clean_spaces(tag)
      tag = dt.tags.create(tag)
      dt.tags.attach(tag, image)
    end
  end
end

-- *************************
local function save_preferences()
  dt.preferences.write( mod, 'group', 'bool', GUI.optionwidgets.group.value )
  dt.preferences.write( mod, 'copy_metadata', 'bool', GUI.optionwidgets.copy_metadata.value )
  dt.preferences.write( mod, 'copy_tags', 'bool', GUI.optionwidgets.copy_tags.value )
  dt.preferences.write( mod, 'add_tags', 'string', GUI.optionwidgets.add_tags.text )
end

-- *************************
local function load_preferences()
  GUI.optionwidgets.group.value = dt.preferences.read( mod, 'group', 'bool' )
  GUI.optionwidgets.copy_metadata.value = dt.preferences.read( mod, 'copy_metadata', 'bool' )
  GUI.optionwidgets.copy_tags.value = dt.preferences.read( mod, 'copy_tags', 'bool' )
  GUI.optionwidgets.add_tags.text = dt.preferences.read( mod, 'add_tags', 'string')
end

-- *************************
-- stop running job
local function stop_job( job )
  job.valid = false
end

-- *************************
local function sanitize_filename(filepath)
  local path = df.get_path(filepath)
  local basename = df.get_basename(filepath)
  local filetype = df.get_filetype(filepath)
  local sanitized = string.gsub(basename, " ", "\\ ")
  return path .. sanitized .. "." .. filetype
end

-- *************************************************
-- main function to run Zerene Stacker
-- *************************************************

local function start_stacking()


  
  dt.print_log( "starting stacking..." )

  save_preferences()

  -- create a new progress_bar displayed in darktable.gui.libs.backgroundjobs
  job = dt.gui.create_job( _"exporting images...", true, stop_job )

  images = dt.gui.selection() --get selected images
  if #images < 2 then --ensure enough images selected
    dt.print(_('not enough images selected, select at least 2 images to stack'))
    if(job.valid) then
      job.valid = false
    end
    return
  end

  local firstimagepath = '' -- this will be path that stacked images get moved to prior to import
  local meta_data = { -- storage for metadata to apply to stacked images
    title = '',
    description = '',
    creator = '',
    rights = '',
  }
  local source_img_table = {} -- table of source images
  local exported_images_table = {} -- table of exported images
  local all_tags = {} -- table of all tags from source images
  local images_to_group = {} -- table of images to be grouped with first images
  local img_count = 0
  local ZereneBatchFound = false
  local stagingfolder = df.sanitize_filename( dt.preferences.read( mod, "StackerStagingFolder", "string" ) )
   -- remove single quotes from folder name
  stagingfolder = string.gsub(stagingfolder,"'","")

  -- check staging folder is empty other than ZereneBatch.xml - depends on lfsfilesystem which may not be available
  if lfs_loaded then
    local staging_clear = true
    for this_file in lfs.dir(stagingfolder) do
      if this_file ~= "." and this_file ~= ".." then
        dt.print_log(' Found '.. this_file)
        if this_file == 'ZereneBatch.xml' then
          ZereneBatchFound = true
        else 
          if string.sub(this_file,1,1) ~= '.' then -- hidden files are ok as Zerene ignores them
            staging_clear=false
            break
          end
        end
      end
    end
    if not (staging_clear) then
      dt.print_log(stagingfolder .. " not empty")
      dt.print(_("Please ensure the folder " .. stagingfolder .. " contains only ZereneBatch.xml"))
      if(job.valid) then
        job.valid = false
      end
      return
    end
    if not(ZereneBatchFound) then
      dt.print_log("ZereneBatch.xml not found")
      dt.print(_("ZereneBatch.xml not found in " .. stagingfolder ))
      if(job.valid) then
        job.valid = false
      end
      return
    end
  end

  -- create tif export of source imaage in staging folder
  for i,image in pairs(images) do

  
    local export_file_name = stagingfolder..os_path_seperator..image.filename..".tif"
    export_image( image, export_file_name)

    -- store tags for all exported images
    copy_tags( all_tags, image )

    -- store exported image name
    table.insert(exported_images_table,export_file_name)

    -- store source image for later grouping, tagging etc
    source_img_table[ #source_img_table+1] = image
 
    if i == 1 then
      -- get path of first source image - stacked files will be moved to this folder prior to import to DT
      dt.print_log( 'image.path= '..image.path )
      dt.print_log( 'sanitized = '..df.sanitize_filename( image.path ) )
      firstimagepath = df.sanitize_filename( image.path )
      firstimagepath = string.gsub(firstimagepath,"'","")
      meta_data.title = image.title
      meta_data.description = image.description
      meta_data.creator = image.creator
      meta_data.rights = image.rights
    else
      -- remember image to group later:
      images_to_group[ #images_to_group + 1 ] = image
    end
    
    if dt.control.ending or not job.valid then
      dt.print_log( _"exporting images canceled!")
      return
    end

    -- update progress_bar
    job.percent = i / #images

    -- sleep for a short moment to give stop_job callback function a chance to run
    dt.control.sleep(10)
  end

  -- stop job and remove progress_bar from ui, but only if not alreay canceled
  if(job.valid) then
    job.valid = false
  end



  -- build zerene command line (see Zenere Natch API details at https://zerenesystems.com/cms/stacker/docs/batchapi)

  local zerene_java_folder = df.sanitize_filename( dt.preferences.read( mod, "ZereneJavaFolder", "string" ) )
  -- remove single quotes from folder name
  zerene_java_folder = string.gsub(zerene_java_folder,"'","")

  local zerene_licfldr = df.sanitize_filename(dt.preferences.read( mod, "ZereneLicFolder", "string" ) )
  -- remove single quotes from folder name
  zerene_licfolder =  string.gsub(zerene_licfldr,"'","")

  local zerene_staging_fldr = df.sanitize_filename(dt.preferences.read( mod, "StackerStagingFolder", "string" ) )
  -- remove single quotes from folder name
  zerene_staging_fldr =  string.gsub(zerene_staging_fldr,"'","")

  -- MacOs - zerene .app is a folder with java runtime in a subfolder

  -- todo - expand to support linux 

  -- Build full commandline based on info here https://zerenesystems.com/cms/stacker/docs/batchapi

  
  if dt.configuration.running_os == 'macos' then
    zerene_commandline = zerene_java_folder .. os_path_seperator .. 'jre' .. os_path_seperator .. 'bin' .. os_path_seperator .. 'java"' -- java runtime packaged with zerene
      -- .. ' -Xmx16384m' -- specifies the amount of memory that can be used by the Java heap.
      .. ' -Dlaunchcmddir=' .. '"' .. zerene_licfolder .. '"' -- directory that holds the Zerene Stacker license key 
      .. ' -Xdock:name="ZereneStacker" -Xdock:icon="' .. zerene_java_folder .. '/../ZereneEurydice.icns"' .. ' -Dapple.laf.useScreenMenuBar=true' -- Settings to integrate in to apple dock etc                            
      .. ' -classpath "' .. zerene_java_folder.. os_path_seperator .. 'ZereneStacker.jar:' -- tell the JRE where to find the Zerene Stacker application and libraries
      .. zerene_java_folder .. os_path_seperator .. 'jai_codec.jar:'
      .. zerene_java_folder .. os_path_seperator .. 'jdom.jar:'
      .. zerene_java_folder .. os_path_seperator .. 'jai_core.jar:'
      .. zerene_java_folder .. os_path_seperator .. 'metadata-extractor-2.4.0-beta-1.jar:'
      .. zerene_java_folder .. os_path_seperator .. 'jai_imageio.jar:'
      .. zerene_java_folder .. os_path_seperator .. 'jdk10hooks.jar"'
  end
    
  if dt.configuration.running_os == 'windows' then
    zerene_java_folder = zerene_java_folder:gsub('"','') -- remove enclosing quotes
    zerene_commandline = zerene_java_folder .. os_path_seperator .. 'jre' .. os_path_seperator .. 'bin' .. os_path_seperator .. 'java"' -- java runtime packaged with zerene
      -- .. ' -Xmx16384m' -- specifies the amount of memory that can be used by the Java heap.
      .. ' -Dlaunchcmddir=' .. '"' .. zerene_licfolder .. '"' -- directory that holds the Zerene Stacker license key 
      .. ' -DjavaBits=64bitJava'
      .. ' -classpath "' .. zerene_java_folder.. os_path_seperator .. 'ZereneStacker.jar;' -- tell the JRE where to find the Zerene Stacker application and libraries
      .. zerene_java_folder .. os_path_seperator .. 'JREextensions' .. os_path_seperator .. '*"'
  end

  -- Common options to modify how zerene runs                                         
  zerene_commandline = zerene_commandline .. ' com.zerenesystems.stacker.gui.MainFrame'
                                          .. ' -noSplashScreen' -- disable splash screen
                                          .. ' -leaveLastBatchProjectOpen' -- leave project open for re-touching etc
-- Add staging folder
  zerene_commandline = '"' .. zerene_commandline .. ' ' ..  zerene_staging_fldr

-- run Zerene Stacker

  job = dt.gui.create_job( _"Running Zerene Stacker...", true, stop_job )
  dt.print_log( 'commandline: '..zerene_commandline )
  local zerene_start_time = os.date("*t",os.time())
  dt.print_log("Zerene Started " .. zerene_start_time.hour ..":" .. zerene_start_time.min .. ":" .. zerene_start_time.sec)

  resp = dsys.external_command( zerene_commandline )
  
  dt.print_log( 'zerene returned '..tostring( resp ) )
  if resp ~= 0 then
    dt.print( _'could not start ZereneStacker application' )
  end
  local zerene_end_time = os.date("*t",os.time())
  dt.print_log("Zerene Finished " .. zerene_end_time.hour ..":" .. zerene_end_time.min .. ":" .. zerene_end_time.sec)

  if(job.valid) then
    job.valid = false
  end

  -- delete exported tif files 
  for i,exp_file_name in pairs(exported_images_table) do
    if (os.remove(exp_file_name)) then
      dt.print_log("Removed " .. exp_file_name)
    else
      dt.print_log("Failed to renove " .. exp_file_name)
    end
  end

  local stackedimages = {} -- table of images to be moved/imported
  if lfs_loaded then
    -- use lfs to find all tif images in staging folder - even if default output filenames are changed in ZereneStacker
    for this_file in lfs.dir(stagingfolder) do
      if this_file ~= "." and this_file ~= ".." then
        dt.print_log('Found '.. this_file)
        if string.sub(this_file,1,1) ~= '.' then -- ignore hidden files
          local file_type = df.get_filetype(this_file)
          if file_type == 'tif' then
            table.insert(stackedimages,this_file)
          end
        end
      end
    end
  else
    -- no lfs - look for specific filenames - will fail to find immages not using default output filename "ZS-OutputImage ZS {method}.tif"
    local zs_base = "ZS-OutputImage ZS "
    local zs_extensions={"PMax.tif","DMap.tif","retouched.tif"}
    for jj = 1, 3 do
      local this_zs_image = zs_base .. zs_extensions[jj]
      -- does this file exist?
      dt.print_log("Checking for " .. this_zs_image)
      if df.check_if_file_exists(stagingfolder .. os_path_seperator .. this_zs_image) then
        table.insert(stackedimages,this_zs_image)
      end
    end
  end
  -- process all images in stackedimages table
  for _,this_file in pairs(stackedimages) do
    -- use df.create_unique_file in case stacked filename already exists in source folder
    local target_filename = df.create_unique_filename( firstimagepath .. os_path_seperator .. this_file)
    local full_filename = stagingfolder .. os_path_seperator .. this_file
    dt.print_log('Source is ' .. this_file .. ' target is ' .. target_filename)
    if target_filename ~= "" then
      -- move stacked image to source folder and import
      if df.file_move(full_filename,target_filename) then
        -- stacked tif now in correct folder and ready for import
        local imported_image = dt.database.import(target_filename)
        if imported_image == nil then
          dt.print_log("Unable to import  " .. target_filename)
          dt.print(_("Unable to move " .. this_file .. " to " .. firstimagepath .. " please check manually"))
        else

          -- group
          -- first group all source images
          if GUI.optionwidgets.group.value == true then
            for _,imagetogroup in pairs( images_to_group ) do
              imagetogroup:group_with( source_img_table[ 1 ] )
            end
          -- now add stacked image to group and make it leader
            imported_image:group_with(source_img_table[1])
            imported_image:make_group_leader()
          end

          -- tags
          if GUI.optionwidgets.copy_tags.value == true then
            insert_tags(imported_image,all_tags)
          end
          add_additional_tags(imported_image)

          -- metadata
          if GUI.optionwidgets.copy_metadata.value == true then
            imported_image.title = meta_data.title
            imported_image.description = meta_data.description
            imported_image.creator = meta_data.creator
            imported_image.rights = meta_data.rights
           end
          end
        end
      else
        -- create_unique_filename may fail if 100 other files with same basename exist, also pernissions may cause move to fail
        dt.print_log("Unable to move " .. this_file .. " to " .. firstimagepath .. " please check manually")
        dt.print(_("Unable to import  " .. target_filename))
      end
  end      
end


-- *************************************************
-- GUI and preferences set up, register lib
-- *************************************************

GUI.optionwidgets.group = dt.new_widget('check_button') {
  label = _('group'),
  value = false,
  tooltip = _('group selected source images and imported result image(s) together'),
  clicked_callback = function(self)
    dt.print_log( "group: "..tostring( self.value ) )
  end,
  reset_callback = function(self)
    self.value = false
  end
}

GUI.optionwidgets.copy_metadata = dt.new_widget('check_button') {
  label = _('copy metadata'),
  value = false,
  tooltip = _('copy metadata first source image to the imported result image(s)'),
  clicked_callback = function(self)
    dt.print_log( "copy metadata: "..tostring( self.value ) )
  end,
  reset_callback = function(self) self.value = false end
}

GUI.optionwidgets.copy_tags = dt.new_widget('check_button') {
  label = _('copy tags'),
  value = false,
  tooltip = _('copy tags from first source image to the imported result image(s)'),
  clicked_callback = function(self)
    dt.print_log( "copy tags: "..tostring( self.value ) )
  end,
  reset_callback = function(self) self.value = false end
}

GUI.optionwidgets.label_settings = dt.new_widget('section_label'){
  label = _('settings')
}

GUI.optionwidgets.label_import_options = dt.new_widget('section_label'){
  label = _('import options')
}

GUI.optionwidgets.add_tags_label = dt.new_widget('label') {
  label = _('new tags'),
  ellipsize = 'start',
  halign = 'start'
}

GUI.optionwidgets.add_tags = dt.new_widget('entry'){
  tooltip = _('Additional tags to be added on import. Seperate with commas, all spaces will be removed'),
  placeholder = _('Enter tags, seperated by commas'),
  editable = true
}

GUI.optionwidgets.add_tags_box = dt.new_widget('box') {
  orientation = 'horizontal',
  GUI.optionwidgets.add_tags_label,
  GUI.optionwidgets.add_tags
}

GUI.options = dt.new_widget('box') {
  orientation = 'vertical',
  GUI.optionwidgets.label_import_options,
  GUI.optionwidgets.group,
  GUI.optionwidgets.copy_metadata,
  GUI.optionwidgets.copy_tags,
  GUI.optionwidgets.add_tags_box
}

GUI.run = dt.new_widget('button'){
  label = _('stack with Zerene Stacker'),
  tooltip =_('run zerene Focus to stack selected images'),
  clicked_callback = function() start_stacking() end
}


-- Preferences - locate Zerene App and staging folder used for image export and script
dt.preferences.register(
  mod, -- script
  "ZereneJavaFolder",	-- name
	"directory",	-- type
  _('Zerene Stacker Java Folder'),	-- label
	_('Select the Zerene Stacker Java folder'),	-- tooltip
  "" -- default,
)

dt.preferences.register(
  mod, -- script
  "ZereneLicFolder",	-- name
	"directory",	-- type
  _('Zerene Licence Folder'),	-- label
	_('Select the folder holding the Zerene licence key'),	-- tooltip
  "" -- default,
)

dt.preferences.register(
  mod, -- script
  "StackerStagingFolder",	-- name
	"directory",	-- type
  _('Stacker Staging Folder'),	-- label
	_('Select the staging folder to be used for stacking'),	-- tooltip
  "" -- default,
)


load_preferences()

local function install_module()
  if not mE.module_installed then
    dt.register_lib( -- register  module
      'ZereneStacker_Lib', -- Module name
      _('Zerene Stacker'), -- name
      true,   -- expandable
      true,   -- resetable
      {[dt.gui.views.lighttable] = {'DT_UI_CONTAINER_PANEL_RIGHT_CENTER', 99}},   -- containers
      dt.new_widget('box'){
        orientation = 'vertical',
        GUI.options,
        GUI.run

      },

      nil,-- view_enter
      nil -- view_leave
    )
  end
end


local function destroy()
  dt.gui.libs["ZereneStacker_Lib"].visible = false
end

local function restart()
  dt.gui.libs["ZereneStacker_Lib"].visible = true

end

if dt.gui.current_view().id == "lighttable" then -- make sure we are in lighttable view
  install_module()  -- register the lib
else
  if not mE.event_registered then -- if we are not in lighttable view then register an event to signal when we might be
    -- https://www.darktable.org/lua-api/index.html#darktable_register_event
    dt.register_event(
      "mdouleExample", "view-changed",  -- we want to be informed when the view changes
      function(event, old_view, new_view)
        if new_view.name == "lighttable" and old_view.name == "darkroom" then  -- if the view changes from darkroom to lighttable
          install_module()  -- register the lib
        end
      end
    )
    mE.event_registered = true  --  keep track of whether we have an event handler installed
  end
end

script_data.destroy = destroy
script_data.restart = restart
script_data.destroy_method = "hide"
script_data.show = restart

return script_data
