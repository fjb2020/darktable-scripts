--[[
    HuginPanorama.lua - process images via Hugin

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

Create panorama using Hugin tools 

When Hugin completes, the result is imported and optionally grouped with the original files.

ADDITIONAL SOFTWARE NEEDED FOR THIS SCRIPT

Hugin and associated commandline tools - https://sourceforge.net/projects/hugin/

ExifTool by Phil Harvey - https://exiftool.org

OPTIONAL ADDITIONAL SOFTWARE USED BY SCRIPT IF INSTALLED

LuaFileSystem - https://luarocks.org/modules/hisham/luafilesystem

See associated HuginPanorama-Readme.md for installation / running options

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


du.check_min_api_version("7.0.0", "HuginProcessor")


-- return data structure for script_manager

local script_data = {}

script_data.metadata = {
  name = "HuginPanorama",
  purpose = "Create panorama using Hugin and tools",
  author = "Fiona Boston <fiona@fbphotography.uk>",
  help = "https://github.com/fjb2020/darktable-scripts"
}



local temp


script_data.destroy = nil -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again

local GUI = { --GUI Elements Table
  optionwidgets = {
    label_run_options    = {},
    use_gui              = {},
    label_import_options = {},
    group                = {},
    copy_metadata        = {},
    copy_tags            = {},
    copy_exif            = {},
    add_tags_box         = {},
    add_tags_label       = {},
    add_tags             = {},
  },
  options = {},
  run = {},
}

local settings = {
  hugin_bin = '',
  hugin_tools = '',
  stagingfolder = '',
  exiftool_bin = '',
}
local paths = {
  firstimagepath = '', -- this will be path that merged images get moved to prior to import
  firstimagebase = '', -- basename of first image for naming output file
  lastimagebase = '',
  firstimagename = '',
  lastimagename = '',
  panoname = '', -- name of final output pano file
  fullpanoname = '',
  blendedname = '',
  pto_path = '',
}

dt.print_log('Running on  ' .. dt.configuration.running_os)
local mod = 'module_HuginProcessor'
local os_path_seperator = '/'
local os_quote = "'"
if dt.configuration.running_os == 'windows' then 
  os_path_seperator = '\\'
  os_quote = '"'
end

-- find locale directory:
local scriptfile = debug.getinfo( 1, "S" )
local localedir = dt.configuration.config_dir .. os_path_seperator .. 'lua' .. os_path_seperator .. 'locale' .. os_path_seperator
--if scriptfile ~= nil and scriptfile.source ~= nil then
--  local path = scriptfile.source:match( "[^@].*[/\\]" )
--  localedir = path..os_path_seperator..'locale'
--end
dt.print_log( "localedir: "..localedir )

-- Tell gettext where to find the .mo file translating messages for a particular domain
local gettext = dt.gettext
gettext.bindtextdomain( 'HuginProcessor', localedir )


-- declare a local namespace and a couple of variables we'll need to install the module
local mE = {}
mE.event_registered = false  -- keep track of whether we've added an event callback or not
mE.module_installed = false  -- keep track of whether the module is module_installed

-- *************************************************
-- utility functions
-- *************************************************

local function _(msgid)
  return gettext.dgettext( 'HuginProcessor', msgid )
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
  dt.preferences.write( mod, 'use_gui', 'bool', GUI.optionwidgets.use_gui.value)
  dt.preferences.write( mod, 'copy_exif', 'bool', GUI.optionwidgets.copy_exif.value)
end

-- *************************
local function load_preferences()
  GUI.optionwidgets.group.value = dt.preferences.read( mod, 'group', 'bool' )
  GUI.optionwidgets.copy_metadata.value = dt.preferences.read( mod, 'copy_metadata', 'bool' )
  GUI.optionwidgets.copy_tags.value = dt.preferences.read( mod, 'copy_tags', 'bool' )
  GUI.optionwidgets.add_tags.text = dt.preferences.read( mod, 'add_tags', 'string')
  GUI.optionwidgets.use_gui.value = dt.preferences.read(mod, 'use_gui', 'bool' )
  GUI.optionwidgets.copy_exif.value = dt.preferences.read(mod, 'copy_exif', 'bool' )
end

-- *************************
-- stop running job
local function stop_job( job )
  job.valid = false
end



-- *************************
local function sanitize_filename(filepath)
  local path = df.get_path(filepath)
  path = string.gsub( path, " ", "\\ " )
  local basename = df.get_basename(filepath)
  local filetype = df.get_filetype(filepath)
  local sanitized = string.gsub(basename, " ", "\\ ")
  return path .. sanitized .. "." .. filetype
end


-- **************************
local function CheckMacApp(Check_cmdline)
  local cmdline = Check_cmdline
  if dt.configuration.running_os == "macos" then
    if string.sub(Check_cmdline,-5) == ".app'" or string.sub(Check_cmdline,-4) == ".app" then
    -- user has entered .app folder rather than actual binary
      cmdline = "open -W -a " .. Check_cmdline
    end
  end
  return(cmdline)
end
-- **************************
local function run_app(app_name, app_cmdline)
  local job = dt.gui.create_job( _"Running " .. app_name, true, stop_job )
  dt.print_log( 'commandline: '..app_cmdline )
  local app_start_time = os.date("*t",os.time())
  dt.print_log(app_name .. " started at " .. app_start_time.hour ..":" .. app_start_time.min .. ":" .. app_start_time.sec)
  
  local rv
  if dt.configuration.running_os == 'windows' then
    rv = dsys.windows_command( app_cmdline )
  else
    rv = dsys.external_command( app_cmdline )
  end

  dt.print_log( app_name .. ' returned '..tostring( rv ) )

  if rv ~= 0 then
    dt.print( _'could not start ' .. app_name .. ' error ' .. tostring(rv) )
  end
  local app_end_time = os.date("*t",os.time())
  dt.print_log(app_name .. " finished at " .. app_end_time.hour ..":" .. app_end_time.min .. ":" .. app_end_time.sec)

  if(job.valid) then
    job.valid = false
  end
  return rv
end


-- **************************
local function getexif(image,exifdata)
  -- reset exifdata tabke

  for k in pairs(exifdata) do
    exifdata[k] = nil
  end

  exifdata["Make"] = image.exif_maker
  exifdata["Model"] = image.exif_model
  exifdata["Lens"] = image.exif_lens
  exifdata["Aperture"] = image.exif_aperture
  exifdata["Exposure"] = image.exif_exposure
  exifdata["Focal_Length"] = image.exif_focal_length
  exifdata["ISO"] = image.exif_iso
  exifdata["Create_Date"] = image.exif_datetime_taken
  exifdata["Latitude"] = image.latitude
  exifdata["Longitude"] = image.longitude
  exifdata["Altitude"] = image.elevation
end

-- **************************
local function check_binary(binaryfile)
  --- df.test_file(fname,'x') doesn't appear to work on windows
  if dt.configuration.running_os == 'windows' then
    if df.check_if_file_exists(binaryfile) then
      return true
    end
  else
    if df.test_file(binaryfile,'x') then
      return true
    end
  end
  return false
end
-- *************************************************
-- get settings set in Lua Options
-- *************************************************
local function get_settings()
  local rv = 1
  settings.hugin_bin = df.sanitize_filename( dt.preferences.read( mod, "hugin_Bin", "string" ) )
  if check_binary(settings.hugin_bin) then
    dt.print_log('Found Hugin binary ' ..settings.hugin_bin )
  else
    dt.print(_('Cannot find Hugin executable '.. settings.hugin_bin .. ' - please check parameters in global options -> Lua Options'))
    dt.print_log('Cannot find Hugin executable '.. settings.hugin_bin)
    return rv
  end

  settings.hugin_tools = df.sanitize_filename( dt.preferences.read( mod, "hugin_tools_directory", "string" ) )
  if df.check_if_file_exists(settings.hugin_tools) then
    dt.print_log('Found Hugin tools directory ' .. settings.hugin_tools )
  else
    dt.print(_('Cannot find hugin tools directory '.. settings.hugin_tools .. ' - please check parameters in global options -> Lua Options'))
    dt.print_log('Cannot find hugin tools directory '.. settings.hugin_tools)
    return rv
  end

  settings.stagingfolder = df.sanitize_filename( dt.preferences.read( mod, "HuginStagingFolder", "string" ) )
  -- remove single quotes from folder name
  settings.stagingfolder = string.gsub(settings.stagingfolder,"'","")
  if not(df.check_if_file_exists(settings.stagingfolder)) then
    dt.print(_('Cannot find staging folder '.. settings.stagingfolder .. ' - please check parameters in global options -> Lua Options'))
    dt.print_log('Found staging folde ' ..  settings.stagingfolder)
    return rv
  end

  settings.exiftool_bin = df.sanitize_filename( dt.preferences.read( mod, "exiftool_bin", "string" ) )
  if check_binary(settings.exiftool_bin) then
    dt.print_log('Found exiftool binary ' .. settings.exiftool_bin )
  else
    dt.print(_('Cannot find exiftool executable '.. settings.exiftool_bin .. ' - please check parameters in global options -> Lua Options'))
    dt.print_log('Cannot find exiftool executable '.. settings.exiftool_bin)
    return rv
  end

  rv = 0
  return rv


end

--- ************************************************
--- Run hugin via gui
--- ************************************************
local function hugin_gui(exp_image_list)

  local hugin_cmd = CheckMacApp(settings.hugin_bin) .. ' ' .. exp_image_list
  local rv = run_app('hugin...',hugin_cmd)
  if rv ~= 0 then
    dt.print_log("Unable to launch hugin gui - error " .. tostring(rv))
  else
    paths.pto_path = settings.stagingfolder ..  os_path_seperator .. paths.lastimagename  .. ' - ' ..  paths.firstimagename .. '.pto'
    paths.panoname = paths.lastimagename  .. ' - ' ..  paths.firstimagename .. '.tif'
    paths.blendedname = settings.stagingfolder .. os_path_seperator .. paths.lastimagename  .. ' - ' ..  paths.firstimagename .. '_blended_fused.tif'
    paths.fullpanoname = settings.stagingfolder .. os_path_seperator .. paths.lastimagename  .. ' - ' ..  paths.firstimagename .. '.tif'
  end
  return rv
end

--- ************************************************
--- Run hugin headless
--- ************************************************
local function hugin_headless(exp_image_list,exported_images_table,img_count)

--[[ 
  details from https://wiki.panotools.org/Panorama_scripting_in_a_nutshell
  
      pto_gen -o project.pto inputfile1, inputfile2, ...
      cpfind -o project.pto --multirow --celeste project.pto
      cpclean -o project.pto project.pto
      linefind -o project.pto project.pto
      autooptimiser -a -m -l -s -o project.pto project.pto
      pano_modify --canvas=AUTO --crop=AUTO -o project.pto project.pto
      nona  -m TIFF_m -o project project.pto
      enblend -o project.tif project0000.tif project0001.tif project0002.tif project003.tif
]]
  local rv
  local cmdline
  paths.panoname = paths.lastimagebase .. '-' .. img_count .. '-huginpano.tif'
  paths.fullpanoname = settings.stagingfolder .. os_path_seperator .. paths.lastimagebase .. '-' .. img_count .. '-huginpano.tif'
  local project_files = {}
  local project_file_list = ''
  for i,exp_file_name in pairs(exported_images_table) do
    project_files[i] = settings.stagingfolder .. os_path_seperator .. 'project' .. string.format("%04d",i-1) .. '.tif'
  end


  -- 1) Generate pto file 
  paths.pto_path = settings.stagingfolder ..  os_path_seperator .. 'project.pto'
  cmdline = settings.hugin_tools .. os_path_seperator .. 'pto_gen' .. ' ' .. exp_image_list .. '-o ' .. os_quote .. paths.pto_path .. os_quote
  rv = run_app('pto_gen', cmdline)

  -- 2) Find control points with cpfind, with celeste to ignore clouds 
  cmdline = settings.hugin_tools .. os_path_seperator .. 'cpfind -o ' .. os_quote .. paths.pto_path .. os_quote .. ' --multirow --celeste ' .. os_quote .. paths.pto_path .. os_quote
  rv = run_app('cpfind', cmdline)

  -- 3) Control point cleaning 
  cmdline = settings.hugin_tools .. os_path_seperator .. 'cpclean -o ' .. os_quote .. paths.pto_path .. os_quote .. ' ' .. os_quote .. paths.pto_path .. os_quote
  rv = run_app('cpclean', cmdline)

  -- 4) Find vertical lines 
  cmdline = settings.hugin_tools .. os_path_seperator .. 'linefind -o ' .. os_quote .. paths.pto_path .. os_quote .. ' ' .. os_quote .. paths.pto_path .. os_quote
  rv = run_app('linefind', cmdline)

  -- 5) Optimize position, do photometric optimization, straighten panorama and select suitable output projection 
  cmdline = settings.hugin_tools .. os_path_seperator .. 'autooptimiser -a -m -l -s -o ' .. os_quote .. paths.pto_path .. os_quote .. ' ' .. os_quote .. paths.pto_path .. os_quote
  rv = run_app('autooptimiser', cmdline)

  -- 6) Calculate optimal crop and optimal size
  cmdline = settings.hugin_tools .. os_path_seperator .. 'pano_modify --canvas=AUTO --crop=AUTO -o ' .. os_quote .. paths.pto_path .. os_quote .. ' ' .. os_quote .. paths.pto_path .. os_quote
  rv = run_app('pano_modify', cmdline)

  -- 7) Remapping (Rendering) images
  cmdline = settings.hugin_tools .. os_path_seperator .. 'nona -m TIFF_m -o ' .. os_quote .. settings.stagingfolder .. os_path_seperator .. 'project' .. os_quote .. ' ' .. os_quote .. paths.pto_path .. os_quote
  rv = run_app('nona', cmdline)

  -- 8) Blending
  cmdline = settings.hugin_tools .. os_path_seperator .. 'enblend -o ' .. os_quote .. paths.fullpanoname .. os_quote .. ' '
  for i,filename in pairs(project_files) do
    cmdline = cmdline .. os_quote .. filename .. os_quote .. ' '
  end 
  rv = run_app('enblend', cmdline)

  -- clean up project files
  for i,filename in pairs(project_files) do
    os.remove(filename)
  end

end

-- **************************************************************
-- main function to run Hugin called by Process with Hugin button
-- **************************************************************

local function run_hugin_Process()

  local exifdata = {}
  local meta_data = { -- storage for metadata to apply to merged images
    title = '',
    description = '',
    creator = '',
    rights = '',
  }
  local source_img_table = {} -- table of source images
  local exported_images_table = {} -- table of exported images
  local all_tags = {} -- table of all tags from source images
  local images_to_group = {} -- table of images to be grouped with first images
  local exp_image_list = "" -- string of exported image filenames to pass to hugin binaries
  

  local exiftool = true
  local rv


  dt.print_log( "starting hugin..." )

  save_preferences()

  -- Check existence of hugin binary files and staging folder
  rv = get_settings()
  if rv ~= 0 then
    dt.print( _'could not locate required folders and binaries' )
  end

  -- check staging folder is empty - depends on lfsfilesystem which may not be available
  if lfs_loaded then
    local staging_clear = true
    for this_file in lfs.dir(settings.stagingfolder) do
      if this_file ~= "." and this_file ~= ".." then
        dt.print_log(' Found '.. this_file)
        if string.sub(this_file,1,1) ~= '.' then -- hidden files are ok 
          staging_clear=false
          break
        end
      end
    end
    if not (staging_clear) then
      dt.print_log(settings.stagingfolder .. " not empty")
      dt.print(_("Please ensure the folder " .. settings.stagingfolder .. " is empty"))
      return
    end
  end

-- **************************************************
-- pre processing - export images into staging folder
-- **************************************************
  -- create a new progress_bar displayed in darktable.gui.libs.backgroundjobs
  local job = dt.gui.create_job( _"exporting images to Hugin...", true, stop_job )
  local images = dt.gui.selection() --get selected images
  local img_count = #images
  if img_count < 2 then --ensure enough images selected
    dt.print(_('not enough images selected, select at least 2 images to process'))
    if(job.valid) then
      job.valid = false
    end
    return
  end
  for i,image in pairs(images) do
    local export_file_name = settings.stagingfolder..os_path_seperator..image.filename..".tif"
    export_image( image, export_file_name)

    -- build list of exported image names to pass into hugin binaries

    exp_image_list = exp_image_list .. os_quote .. export_file_name .. os_quote .. ' '
    -- store tags for all exported images
    copy_tags( all_tags, image )
    -- store exported image name
    table.insert(exported_images_table,export_file_name)
    -- store source image for later grouping, tagging etc
    source_img_table[ #source_img_table+1] = image
    if i == 1 then
      -- get path of first source image - merged files will be moved to this folder prior to import to DT
      dt.print_log( 'image.path= '..image.path )
      paths.firstimagepath = df.sanitize_filename( image.path )
      paths.firstimagepath = string.gsub(paths.firstimagepath,"'","")
      paths.firstimagebase= df.get_basename(image.filename)
      paths.firstimagename = df.get_filename(image.filename)
      meta_data.title = image.title
      meta_data.description = image.description
      meta_data.creator = image.creator
      meta_data.rights = image.rights
      -- get exif data if requested
      if GUI.optionwidgets.copy_exif.value == true then
        getexif(image,exifdata)
      end

    else
      -- remember image to group later:
      images_to_group[ #images_to_group + 1 ] = image
    end
    if i == img_count then
      -- last image
      paths.lastimagename = df.get_filename(image.filename)
      paths.lastimagebase = df.get_basename(image.filename)
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

-- *************************************************
-- create panorama 
-- *************************************************

  if GUI.optionwidgets.use_gui.value == true then
    rv = hugin_gui(exp_image_list)
  else
    rv = hugin_headless(exp_image_list,exported_images_table,img_count)
  end

-- *************************************************
-- post processing - import, cleanup, metadata etc
-- *************************************************

-- delete exported tif files and pto file
  for i,exp_file_name in pairs(exported_images_table) do
    os.remove(exp_file_name)
  end
  os.remove(paths.pto_path)

  -- EXIF Data    
  exiftool = false
  if GUI.optionwidgets.copy_exif.value == true  then
    if settings.exiftool_bin ~= '' then
    -- try to copy exifdata via exiftool if reequested prior to import
      local sourcefile = os_quote .. paths.firstimagepath .. os_path_seperator .. paths.firstimagename .. os_quote
      local exiftool_cmd = settings.exiftool_bin .. ' -m -overwrite_original -tagsfromfile ' .. sourcefile .. ' ' .. os_quote .. paths.fullpanoname .. os_quote
      dt.print_log("Running exiftool " .. exiftool_cmd)
      dt.print("Copying metadata vis Exiftool")
      rv = run_app('exiftool...', exiftool_cmd)
      dt.print_log("Exiftool returned " .. tostring(rv))
      if rv == 0 then
        exiftool = true
      end
    end
  end
  
  -- use df.create_unique_file in case pano stacked filename already exists in source folder
  local target_filename = df.create_unique_filename( paths.firstimagepath .. os_path_seperator .. paths.panoname )
  dt.print_log('Source is ' .. paths.fullpanoname .. ' target is ' .. target_filename)
  if target_filename ~= "" then
    -- move stacked image to source folder and import
    if df.file_move(paths.fullpanoname,target_filename) then
      -- stacked tif now in correct folder and ready for import
      dt.print_log("Moved " .. paths.fullpanoname .. " to " .. target_filename)
      local imported_image = dt.database.import(target_filename)
      if imported_image == nil then
        dt.print_log("Unable to import  " .. target_filename)
        dt.print(_("Unable to move " .. paths.fullpanoname .. " to " .. paths.firstimagepath .. " please check manually"))
      else
        dt.print_log("Imported " .. target_filename)
      -- check rotation if source images are portrait
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
        -- EXIF Data
        if GUI.optionwidgets.copy_exif.value == true and not(exiftool) then
          -- no exiftool so copy limited exif into imported DT database entry for pano image
          -- exif of tif file will not be changed
          imported_image.exif_maker = exifdata["Make"]
          imported_image.exif_model = exifdata["Model"]
          imported_image.exif_lens =  exifdata["Lens"]
          imported_image.exif_aperture = exifdata["Aperture"]
          imported_image.exif_exposure = exifdata["Exposure"]
          imported_image.exif_focal_length = exifdata["Focal_Length"]
          imported_image.exif_iso = exifdata["ISO"]
          imported_image.exif_datetime_taken = exifdata["Create_Date"]
          imported_image.latitude =  exifdata["Latitude"]
          imported_image.longitude =  exifdata["Longitude"]
          imported_image.elevation =  exifdata["Altitude"]
        end
      end
    end
  else
    -- create_unique_filename may fail if 100 other files with same basename exist, also pernissions may cause move to fail
    dt.print_log("Unable to move " .. paths.fullpanoname .. " to " .. paths.firstimagepath .. " please check manually")
    dt.print(_("Unable to import  " .. target_filename))
  end

--- *************************************************
--- End of Function run_hugin_Process()
--- *************************************************
end


-- *************************************************
-- GUI and preferences set up, register lib
-- *************************************************

GUI.optionwidgets.group = dt.new_widget('check_button') {
  label = _('group'),
  value = false,
  tooltip = _('group selected source images and imported result image together'),
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
  tooltip = _('copy metadata first source image to the imported result image'),
  clicked_callback = function(self)
    dt.print_log( "copy metadata: "..tostring( self.value ) )
  end,
  reset_callback = function(self) self.value = false end
}

GUI.optionwidgets.copy_tags = dt.new_widget('check_button') {
  label = _('copy tags'),
  value = false,
  tooltip = _('copy tags from first source image to the imported result image'),
  clicked_callback = function(self)
    dt.print_log( "copy tags: "..tostring( self.value ) )
  end,
  reset_callback = function(self) self.value = false end
}

GUI.optionwidgets.label_settings = dt.new_widget('section_label'){
  label = _('settings')
}


GUI.optionwidgets.label_run_options = dt.new_widget('section_label'){
  label = _('run options')
}

GUI.optionwidgets.use_gui = dt.new_widget('check_button') {
  label = _('use Hugin GUI'),
  value = false,
  tooltip = _('Use Hugin GUI - if uncheck process will run hidden'),
  clicked_callback = function(self)
    dt.print_log( "use gui: "..tostring( self.value ) )
  end,
  reset_callback = function(self) self.value = false end
}


GUI.optionwidgets.copy_exif = dt.new_widget('check_button') {
  label = _('Copy EXIF'),
  value = false,
  tooltip = _('Copy EXIF from first image in pano group to pano image'),
  clicked_callback = function(self)
    dt.print_log( "Copy exif: "..tostring( self.value ) )
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
  GUI.optionwidgets.label_run_options,
  GUI.optionwidgets.use_gui,
  GUI.optionwidgets.label_import_options,
  GUI.optionwidgets.group,
  GUI.optionwidgets.copy_metadata,
  GUI.optionwidgets.copy_tags,
  GUI.optionwidgets.copy_exif,
  GUI.optionwidgets.add_tags_box
}

GUI.run = dt.new_widget('button'){
  label = _('Process with Hugin'),
  tooltip =_('Process selected images with Hugin'),
  clicked_callback = function() run_hugin_Process() end
}

-- ******************************************************************
-- Preferences - locate executables for Hugin, hugin_tools, exiftools
dt.preferences.register(
  mod, -- script
  "exiftool_bin",	-- name
	"file",	-- type
  _('exiftool executable'),	-- label
	_('Select the executable for exiftool'),	-- tooltip
  "" -- default,
)

dt.preferences.register(
  mod, -- script
  "HuginStagingFolder",	-- name
	"directory",	-- type
  _('Hugin Staging Folder'),	-- label
	_('Select the staging folder to be used for Hugin processing'),	-- tooltip
  "" -- default,
)

dt.preferences.register(
  mod, -- script
  "hugin_Bin",	-- name
	"file",	-- type
  _('Hugin executable'),	-- label
	_('Select the executable for Hugin'),	-- tooltip
  "" -- default,
)

dt.preferences.register(
  mod, -- script
  "hugin_tools_directory",	-- name
	"directory",	-- type
  _('hugin_tools directory'),	-- label
	_('Select the directory where the hugin tools are located'),	-- tooltip
  "" -- default,
)






load_preferences()

local function install_module()
  if not mE.module_installed then
    dt.register_lib( -- register  module
      'HuginProcessor_Lib', -- Module name
      _('Hugin Panorama'), -- name
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
  dt.gui.libs["HuginProcessor_Lib"].visible = false
end

local function restart()
  dt.gui.libs["HuginProcessor_Lib"].visible = true

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
