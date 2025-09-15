--[[

     dxo_pureraw - processes raw images in darktable with DxO_PureRAW 

    Copyright (C) 2024 Fiona Boston <fiona@fbphotography.uk>.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

    ================================================================

    dxo_pureraw 

    This script adds a new panel to integrate DxO_PureRAW software into darktable
    to be able to pass or export a bunch of images to Zerene Stacker, reimport the result(s) and
    optionally group the images and optionally copy and add tags to the imported image(s)
    When DxO.Pureraw exits, the result files are imported and optionally grouped with the original files.

    ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT
    * dxo_pureraw 3 - http://www.dxo.com

    USAGE 
    * require this script from your main lua file
    * specify the location of the DxO.pureRAW executable in Lua Options

    * select an image or images for processing with DxO pureRAW
    * Expand the DxO pureRAW panel (ighttable view) 
    * select options as required:
        group - group processed image with associated RAW image
        copy tags - copy tags from RAW image to processed image
        copy metadata - copy metadata (title, description, creator, rights) to processed image
        new tags - tags to be added to the new processed image

    * Press "Process with DxO_pureRAW"
    * If the image has already been processed by DxO and the output exists, DxO prompts either to overwrite or use a unique filename -
      this script does not handle the unqiue filename option so the output will not automatically be imported back into Darktable

    * Process the images with DxO.PureRAW then save the results
    * Exit DxO_pureRAW
    * The resulting image(s) will be imported 

    CAVEATS

    * This script was tested using using darktable 4.8.0 and above

      - macOS Sonoma 14.5 on Apple Silcon
      - Windows 11 ARM running in a VM on Apple Silicon
    
      - DxO PureRAW 3 and 4.7
    
    BUGS, COMMENTS, SUGGESTIONS
    * Send to Fiona Boston, fiona@fbphotography.uk

]]

local dt = require 'darktable'
local du = require "lib/dtutils"
local df = require 'lib/dtutils.file'
local log = require "lib/dtutils.log"
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

du.check_min_api_version("7.0.0", "DxO_pureRAW")

local script_data = {}
script_data.metadata = {
  name = "DxO_PureRAW",
  purpose = "process images in DxO_PureRAW",
  author = "Fiona Boston <fiona@fbphotography.uk>",
  help = "https://github.com/fjb2020/darktable-scripts",
}
script_data.destroy = nil -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again

local gettext = dt.gettext




local GUI = { --GUI Elements Table
  optionwidgets = {
    group                = {},
    copy_metadata        = {},
    label_import_options = {},
    copy_tags            = {},
    add_tags_box         = {},
    add_tags_label       = {},
    add_tags             = {},
  },
  options = {},
  run = {},
  cancel = {},
  btnbox = {},
}

local params = {
  DxO_exec = '',
  DxO_version = '',
  DxO_extensions = {},
  DxO_cmd = '',
  DxO_staging = '',
  DxO_timeout = '',
  img_table = {},
  img_count = 0,
  img_list = "",
  img_path = "",
  opfile_table = {},
}

local mod = 'module_DxO_PureRAW'
local os_path_seperator = '/'
if dt.configuration.running_os == 'windows' then os_path_seperator = '\\' end

-- find locale directory:
local scriptfile = debug.getinfo( 1, "S" )
local localedir = dt.configuration.config_dir..'/lua/locale/'
if scriptfile ~= nil and scriptfile.source ~= nil then
  local path = scriptfile.source:match( "[^@].*[/\\]" )
  localedir = path..os_path_seperator..'locale'
end
--dt.print_log( "localedir: "..localedir )
gettext.bindtextdomain( 'DxO_pureRAW', localedir )

local DxO_job
local cancel_pressed = false

-- declare a local namespace and a couple of variables we'll need to install the module
local mE = {}
mE.event_registered = false  -- keep track of whether we've added an event callback or not
mE.module_installed = false  -- keep track of whether the module is module_installed


-- *************************************************
-- functions
-- *************************************************



function _(msgid)
  -- Define a function called _ to make the code more readable and have it call dgettext 
  -- with the proper domain.
  return gettext.dgettext("dxo_pureraw", msgid)
end




-- *************************************************
local function Get_DxO_app()

  params.DxO_exec = df.sanitize_filename( dt.preferences.read( mod, "DxO_pureRAWExe", "string" ) )
  --dt.print_log("DxO_exec is " .. params.DxO_exec)

  if dt.configuration.running_os == 'macos' then
    if df.test_file(params.DxO_exec,"e") then
      --dt.print_log("Found " .. params.DxO_exec)
    else
      dt.print("Cannot find " .. params.DxO_exec .. "  - Please check DxO_pureRAW executable in Lua options ...")
      return false
    end
    if string.sub(params.DxO_exec,-5) ~= ".app'" then
     dt.print("Please use the .app application ...")
     return false
    end
  end



  params.DxO_version = ''
  if params.DxO_exec:find("3") then
    params.DxO_version = '3'
  end
  if params.DxO_exec:find("4") or params.DxO_exec:find("5") then
    params.DxO_version = '4'
    if params.DxO_exec:find("5") then
       params.DxO_version = '5'
    end
    params.DxO_staging = df.sanitize_filename( dt.preferences.read( mod, "DxOStagingFolder", "string" ) )
    -- remove single quotes from folder name
    params.DxO_staging = string.gsub(params.DxO_staging,"'","")
    if not(df.check_if_file_exists(params.DxO_staging)) then
      dt.print(_('Cannot find DxO staging folder '.. params.DxO_staging .. ' - please check parameters in global options -> Lua Options'))
      return false
    end
    params.DxO_timeout = dt.preferences.read( mod, 'DxOTimeout', "string")
    params.DxO_timeout = tonumber(params.DxO_timeout)
    if (params.DxO_timeout < 0) or (params.DxO_timeout > 30) then
      dt.print(_('Invalid DxO Timeout specifed - 0 to 30 allowed, please check in Lua options'))
      return false
    end
  end
  if params.DxO_version == '3' then
    params.DxO_extensions = {"_DxO_DeepPRIMEXD.dng","_DxO_DeepPRIME.dng","_DxO_DeepPRIMEXD.tif","_DxO_DeepPRIME.tif","_DxO_DeepPRIMEXD.jpg","_DxO_DeepPRIME.jpg"}
  else
    params.DxO_extensions = {"-DxO_DeepPRIMEXD.dng","-DxO_DeepPRIME.dng","-DxO_DeepPRIME XD2s.dng","-DxO_DeepPRIME XD2s_XD.dng","-DxO_DeepPRIME XD3 X-Trans.dng"}
  end
  params.DxO_cmd = params.DxO_exec
  return true
end

-- *************************************************

local function sanitize_filename(filepath)
  local path = df.get_path(filepath)
  local basename = df.get_basename(filepath)
  local filetype = df.get_filetype(filepath)
  local sanitized = string.gsub(basename, " ", "\\ ")
  return path .. sanitized .. "." .. filetype
end

-- *************************************************
--removes spaces from the front and back of passed in text
local function clean_spaces(text)
  text = string.gsub(text,'^%s*','')
  text = string.gsub(text,'%s*$','')
  return text
end
-- *************************************************
local function save_preferences()
  dt.preferences.write( mod, 'group', 'bool', GUI.optionwidgets.group.value )
  dt.preferences.write( mod, 'copy_tags', 'bool', GUI.optionwidgets.copy_tags.value )
  dt.preferences.write( mod, 'copy_metadata', 'bool', GUI.optionwidgets.copy_metadata.value )
  dt.preferences.write( mod, 'add_tags', 'string', GUI.optionwidgets.add_tags.text )
end
-- *************************************************
local function load_preferences()
  GUI.optionwidgets.group.value = dt.preferences.read( mod, 'group', 'bool' )
  GUI.optionwidgets.copy_tags.value = dt.preferences.read( mod, 'copy_tags', 'bool')
  GUI.optionwidgets.copy_metadata.value = dt.preferences.read( mod, 'copy_metadata', 'bool')
  GUI.optionwidgets.add_tags.text = dt.preferences.read( mod, 'add_tags', 'string')
end

-- *************************************************
local function sleep(seconds)
  local delay = seconds * 1000
  dt.control.sleep(delay) -- milliseconds
end

-- *************************************************
-- stop running export
local function stop_job( job )
  job.valid = false
end
-- *************************************************
local function getfilesize(filename)
  local thisfilesize
  local thisfile = io.open(filename,'r')
  if thisfile then
    thisfilesize = thisfile:seek("end")
  else
    thisfilesize = 0
  end
  io.close(thisfile)
  return thisfilesize

end


-- *************************************************
local function check_DxO_processed(checkfile)
  --dt.print_log("Checking for " .. checkfile)
  if df.check_if_file_exists(checkfile) then
    -- file exists - what is filesize
    local thisfilesize = getfilesize(checkfile)
    --dt.print_log(checkfile .. " exists, size is  " ..  thisfilesize)
    if thisfilesize > 0 then
      sleep (5) -- wait 5 seconds just to make sure file is properly saved by DxO
      return true
    else
      return false
    end
  end
  return false
end

-- ************************************************
-- Run DxO_pureRAW v3
-- ************************************************
local function run_pureRAW_v3()

    -- PureRAW version 3 terminates on completion of processing so we can easily detect when it's complete
  
    -- create a new progress_bar displayed in darktable.gui.libs.backgroundjobs
    DxO_job = dt.gui.create_job( _"Running DxO_pureRAW v3 ...", true, stop_job )

    if dt.configuration.running_os == "macos" then
      params.DxO_cmd = "open -W -a " .. params.DxO_cmd
    end
    params.DxO_cmd = params.DxO_cmd .. " " .. params.img_list
    --dt.print_log( 'commandline: ' .. params.DxO_cmd )

    local dxo_start_time = os.date("*t",os.time())
    --dt.print_log( 'starting DxO_pureRAW at ' .. dxo_start_time.hour ..":" .. dxo_start_time.min .. ":" .. dxo_start_time.sec)
    local resp
    if dt.configuration.running_os == 'windows' then
      resp = dsys.windows_command( params.DxO_cmdDxO_cmd )
    else
      resp = dsys.external_command( params.DxO_cmd )
    end
    
    if resp ~= 0 then
      --dt.print_log( 'DxO_pureRAW returned '..tostring( resp ) )
      dt.print( _'could not start DxO_pureRAW application - is it set correctly in Lua Options?' )
      if(DxO_job.valid) then
        DxO_job.valid = false
      end
      return false
    end
    
    local dxo_end_time = os.date("*t",os.time())
    -- dt.print_log("DxO Finihsed " .. dxo_end_time.hour ..":" .. dxo_end_time.min .. ":" .. dxo_end_time.sec)
    if(DxO_job.valid) then
      DxO_job.valid = false
    end
    return true
end

-- ************************************************
local function cleanup_DxO4()

  -- process has been cancelled

  for i = 1, params.img_count do
    if params.opfile_table[i][2] then
      local checkfile = params.DxO_staging .. os_path_seperator .. params.opfile_table[i][2]
      --dt.print_log("Checking " .. checkfile)
      if df.check_if_file_exists(checkfile) then
        -- this will remove any files processed so far, but as DxO processing itself isn't being cancelled there may be other files created after this script stops.
          os.remove(checkfile)
      end
    end
  end

end

-- ************************************************
-- Run DxO_pureRAW v4/5

local function run_pureRAW_v45()
--[[

    PureRAW version 4 continues to run in the background on completion of processing 
    we can't therefore wait fot the open command to complete - it will 'never' complete if we run it in wait mode
    
    so we have a different approach to that checks for the existance of the output files to assume process completion

]]
  -- check staging folder is empty - depends on lfsfilesystem which may not be available
  if lfs_loaded then
    local staging_clear = true
    for this_file in lfs.dir(params.DxO_staging) do
      if this_file ~= "." and this_file ~= ".." then
        dt.print_log(' Found '.. this_file)
        if string.sub(this_file,1,1) ~= '.' then -- hidden files are ok 
          staging_clear=false
          break
        end
      end
    end
    if not (staging_clear) then
      dt.print_log(params.DxO_staging .. " not empty")
      dt.print(_("Please ensure the folder " .. params.DxO_staging.. " is empty"))
      return false
    end
  end
      -- create a new progress_bar displayed in darktable.gui.libs.backgroundjobs
  DxO_job = dt.gui.create_job( _"Running DxO_pureRAW v4 ...", true, stop_job )

  if dt.configuration.running_os == "macos" then
    -- open without -w (wait) option so control will come back immediately
    params.DxO_cmd = "open -a " .. params.DxO_cmd
  end
  if dt.configuration.running_os == "windows" then 
    
    params.DxO_cmd = "start " .. '"Run DxO pureRAW 4"' .. " " .. params.DxO_cmd
  end
  params.DxO_cmd = params.DxO_cmd .. " " .. params.img_list
  dt.print_log( 'commandline: ' .. params.DxO_cmd )
  dt.print( 'Activating DxO_pureRAW ...')
  
  local resp
  if dt.configuration.running_os == 'windows' then
    resp = dsys.windows_command( params.DxO_cmd )
  else
    resp = dsys.external_command( params.DxO_cmd )
  end
  if DxO_job.valid then
    DxO_job.valid = false
  end
  -- now wait for output files to be created
  -- We assume that the DxO staging folder has been selected as the output folder in pureRAW 4/5
  -- we also assume that the filename format will be imagebase-processmode.dng - maybe will parameterise this in future
  --
  local processed_images = 0
  local DxO_complete = false
  local dxo_start_time = os.time()
  DxO_job = dt.gui.create_job( _"Waiting for DxO_pureRAW " .. params.DxO_version .. " ...", true, stop_job )
  while not DxO_complete do
    if cancel_pressed then
      if(DxO_job.valid) then
        DxO_job.valid = false
      end
      cleanup_DxO4()
      cancel_pressed = false
      return false
    end

    -- stop processing if 'stopjob; file is createad in stagingfolder'
    if df.check_if_file_exists(params.DxO_staging .. os_path_seperator .. "stopjob") then
      if(DxO_job.valid) then
        DxO_job.valid = false
      end
      return false
    end

    local dxo_current_time = os.time()
    -- dt.print_log("Total wait is " .. os.difftime(dxo_current_time,dxo_start_time) .. " seconds")
    if(DxO_job.valid) then
      DxO_job.valid = false
    end
    DxO_job = dt.gui.create_job( _"Waiting for DxO_pureRAW " .. params.DxO_version .. " - " .. processed_images .. " of " .. params.img_count .. " processed, " .. string.format("%d",os.difftime(dxo_current_time,dxo_start_time)) .. " seconds", true, stop_job   )
    -- wait 10 seconds then see if images are ready
    sleep(10)
    
    for i = 1, params.img_count do
      if params.opfile_table[i][4] == false then
        local foundOpFile = false
        for p = 1, #params.DxO_extensions do
          local checkfile = df.get_basename(params.opfile_table[i][1].filename) .. params.DxO_extensions[p]
          dt.print_log("checking for " .. checkfile .. ' from ' .. params.opfile_table[i][1].filename)
          local rv = check_DxO_processed(params.DxO_staging .. os_path_seperator .. checkfile)
          if rv then
            params.opfile_table[i][2] =  checkfile
            params.opfile_table[i][4] = rv
            foundOpFile = true
            dt.print_log("Found " .. checkfile)
            break
          end
        end
      end
    end

    -- logic to check if all images have been processed (or we're out of time)
    local all_complete = true
    local old_proceseed_images = processed_images
    processed_images = 0
    for i = 1, params.img_count do
      if params.opfile_table[i][4] == true then
        processed_images = processed_images + 1
        -- reest timeout
      else
        all_complete = false
      end
    end
    if processed_images > old_proceseed_images then
      -- another image has been processed - reset timeout
      dxo_start_time = os.time()
    end
    if all_complete then
      DxO_complete = true
    end

-- put in a time check here to break out of loop eventually - 
-- in case not all expected images have been processed - don't want to loop forever
    local dxo_current_time = os.time()
    if os.difftime(dxo_current_time,dxo_start_time) > (params.DxO_timeout * 60) then
      DxO_complete = true
    end

  end


  if(DxO_job.valid) then
    DxO_job.valid = false
  end
  return true

end


-- ************************************************
-- import image
-- ************************************************
local function import_DxO(this_dxo_image,this_raw_img,move_DxO)

  --dt.print_log("Found " ..  this_dxo_image)
  if move_DxO then
    -- move Dxo Image to same directory as raw image
    -- use df.create_unique_file in case f DxO filename already exists in source folder
    local target_filename = df.create_unique_filename( this_raw_img.path .. os_path_seperator .. this_dxo_image  )
    local source_image = params.DxO_staging .. os_path_seperator .. this_dxo_image
    --dt.print_log('Source is ' .. source_image .. ' target is ' .. target_filename)
    if target_filename ~= "" then
      -- move stacked image to source folder and import
      if df.file_move(source_image,target_filename) then
        -- stacked tif now in correct folder and ready for import
        --dt.print_log("Moved " .. source_image .. " to " .. target_filename)
        this_dxo_image = target_filename
      else
        return false
      end
    else
      return false
    end
  end

  --dt.print_log("DxO file is " .. this_dxo_image)
  local imported_image = dt.database.import(this_dxo_image)
  -- images already in the database will have any sidecar files re-read 
  if imported_image == nil then
    dt.print_error("Failed to import " .. this_dxo_image)
    return false
  end
  --dt.print_log("Imported " .. imported_image.path .. "/" .. imported_image.filename)
  if GUI.optionwidgets.copy_tags.value == true then
    -- copy tags except 'darktable' tags
    local raw_tags = dt.tags.get_tags(this_raw_img)
    for _,this_tag in pairs(raw_tags) do
      if not (string.sub(this_tag.name,1,9) == "darktable") then
        dt.tags.attach(this_tag,imported_image)
      end
    end
  end
  -- add extra tag
  local set_tag = GUI.optionwidgets.add_tags.text
  if set_tag ~= nil then -- add additional user-specified tags
    for tag in string.gmatch(set_tag, '[^,]+') do
      tag = clean_spaces(tag)
      tag = dt.tags.create(tag)
      dt.tags.attach(tag, imported_image)
    end
  end
    
  if GUI.optionwidgets.copy_metadata.value == true then
    -- metadata - title, desc, creator, rights
    imported_image.title = this_raw_img.title
    imported_image.description = this_raw_img.description
    imported_image.creator = this_raw_img.creator
    imported_image.rights = this_raw_img.rights
  end

  if GUI.optionwidgets.group.value == true then
    -- group if requested and make leader
    imported_image:group_with(this_raw_img)
    imported_image:make_group_leader()
  end
  return true
end
-- ************************************************
-- main function
-- ************************************************
local function start_processing()
  local exported_images_table = {}
  -- dt.print_log( "starting DxO_pureRAW processing..." )

  save_preferences()

  local images = dt.gui.selection() --get selected images
  params.img_count = #images
  if params.img_count < 1 then --ensure enough images selected
    dt.print(_('Please select at least 1 image to process'))
    return
  end

  -- check DxO app exists and which version it is
  local rv = Get_DxO_app()
  if not(rv) then
    return
  end
    -- image list comprises raw file names of all images in selection
    -- also build list of expected images being exported by DXO Pureraw for later import (pureRAW 4 only)
  --local today = os.date("*t")
  --local opfile_prefix = today.year .. string.format("%02d",today.month) .. string.format( "%02d",today.day)

  for i,raw_img in pairs(images) do
    -- appeand this raw image to string of images to be sent to DxO_PureRAW
    params.img_list = params.img_list .. '"' ..  raw_img.path  .. os_path_seperator .. raw_img.filename .. '" '
    table.insert(params.img_table,raw_img)
    params.opfile_table[i] = {}
    params.opfile_table[i][1] = raw_img
    params.opfile_table[i][4] = false -- flag to indicate file has been processed by DxO_PureRAW and is ready to import


  end

-- Run process dependent on DxO verion
  if params.DxO_version == '3' then
    rv = run_pureRAW_v3()
  else
    rv = run_pureRAW_v45()
  end

  if not(rv) then
    return
  end
  -- Import processed images into darktable
  local move_DxO

  


  for ii = 1, params.img_count do

    if(DxO_job.valid) then
      DxO_job.valid = false
    end
    DxO_job = dt.gui.create_job( _"Importing " .. ii .. " of " .. params.img_count .. " images ", true, stop_job   )

    
    local this_raw_img = params.opfile_table[ii][1]
    local img_type = string.sub(this_raw_img.filename,-3)
    --dt.print_log("Post processing " .. this_raw_img.filename)
    if params.DxO_version == '3' then
      -- look for DxO images based on known extensions
      move_DxO = false
      local this_dxo_image_base = (df.chop_filetype(this_raw_img.path .. os_path_seperator .. this_raw_img.filename)) .. "-" .. img_type
      for jj = 1, #params.DxO_extensions do
        local this_dxo_image = sanitize_filename(this_dxo_image_base .. params.DxO_extensions[jj])
        if df.check_if_file_exists(this_dxo_image) then
          rv = import_DxO(this_dxo_image,this_raw_img,move_DxO)
        end 
      end
    else
      move_DxO = true
      local this_dxo_image = params.opfile_table[ii][2]
      dt.print_log("Importing - " .. this_dxo_image)
      if df.check_if_file_exists(params.DxO_staging .. os_path_seperator .. this_dxo_image) then
        rv = import_DxO(this_dxo_image,this_raw_img,move_DxO)
      end
    end
  end
  if(DxO_job.valid) then
    DxO_job.valid = false
  end
end


-- ******************************************************
local function cancel_processing()
  dt.print_log("Cancel pressed")
  cancel_pressed = true
end


-- ******************************************************
-- Setup and Install module
-- ******************************************************


GUI.optionwidgets.group = dt.new_widget('check_button') {
  label = _('group'),
  value = false,
  tooltip = _('group processed image with original RAW'),
  clicked_callback = function(self)
    dt.print_log( "group: "..tostring( self.value ) )
  end,
  reset_callback = function(self)
    self.value = false
  end
}


GUI.optionwidgets.copy_tags = dt.new_widget('check_button') {
  label = _('copy existing tags'),
  value = false,
  tooltip = _('copy all tags from all source images to the imported result image(s)'),
  clicked_callback = function(self)
    dt.print_log( "copy tags: "..tostring( self.value ) )
  end,
  reset_callback = function(self) self.value = false end
}

GUI.optionwidgets.copy_metadata = dt.new_widget('check_button') {
  label = _('copy Metadataa'),
  value = false,
  tooltip = _('copy metadata (title, desc, creator, rights) to processed image'),
  clicked_callback = function(self)
    dt.print_log( "copy tags: "..tostring( self.value ) )
  end,
  reset_callback = function(self) self.value = false end
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
  GUI.optionwidgets.copy_tags,
  GUI.optionwidgets.copy_metadata,
  GUI.optionwidgets.add_tags_box
}

GUI.run = dt.new_widget('button'){
  label = _('Process with DxO_PureRAW'),
  tooltip =_('run DxO_PureRAW on selected images'),
  clicked_callback = function() start_processing() end
}

GUI.cancel = dt.new_widget("button"){
  label = _("Cancel Waiting"),
  tooltip = _("Cancel Darktable Wait for DxO"),
  clicked_callback = function() cancel_processing() end
}

GUI.btnbox = dt.new_widget("box"){
  orientation = "horizontal",
  GUI.run,
  GUI.cancel
}

-- Preferences - locate DxO_PureRAW executable, setup staging folder (for DxO 4)

dt.preferences.register(
  mod, -- script
  "DxOTimeout",	-- name
	"string",	-- type
  _('DxO 4/5 Timeout (mins 0 - 30)'),	-- label
	_('Set the max time in minutes (0 - 30) allowed per image for processing by DxO 4 or 5'),	-- tooltip
  "2" -- default,
)

dt.preferences.register(
  mod, -- script
  "DxOStagingFolder",	-- name
	"directory",	-- type
  _('DxO 4/5 Staging Folder'),	-- label
	_('Select the staging folder used by DxO 4 or 5'),	-- tooltip
  "5" -- default,
)


dt.preferences.register(
  mod, -- script
  "DxO_pureRAWExe",	-- name
	"file",	-- type
  _('DxO_pureRAW executable'),	-- label
	_('Select the executable DxO_PureRAW'),	-- tooltip
  "" -- default,
)



load_preferences()


local function install_module()
  if not mE.module_installed then
    dt.register_lib( -- register  module
      'DxO_pureRAW_Lib', -- Module name
      _('DxO Pureraw'), -- name
      true,   -- expandable
      true,   -- resetable
      {[dt.gui.views.lighttable] = {'DT_UI_CONTAINER_PANEL_RIGHT_CENTER', 99}},   -- containers
      dt.new_widget('box'){ -- GUI widgets
        orientation = 'vertical',
        GUI.options,
        GUI.btnbox

      },

      nil,-- view_enter
      nil -- view_leave
    )
  end
end


local function destroy()
  dt.gui.libs["DxO_pureRAW_Lib"].visible = false
end

local function restart()
  dt.gui.libs["DxO_pureRAW_Lib"].visible = true

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
