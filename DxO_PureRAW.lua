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
    * dxo_pureraw - http://www.dxo.com

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
    * This script was tested using using darktable 4.8.0 and 4.8.1 on the following platforms:

      - macOS Sonoma 14.5 on Apple Silcon
      - Windows 11 ARM running in a VM on Apple Silicon
    * 
    * 
    BUGS, COMMENTS, SUGGESTIONS
    * Send to Fiona Boston, fiona@fbphotography.uk

]]

local dt = require 'darktable'
local du = require "lib/dtutils"
local df = require 'lib/dtutils.file'
local log = require "lib/dtutils.log"
local dsys = require 'lib/dtutils.system'


du.check_min_api_version("7.0.0", "DxO_pureRAW")

local script_data = {}
local temp

script_data.destroy = nil -- function to destory the script
script_data.destroy_method = nil -- set to hide for libs since we can't destroy them commpletely yet, otherwise leave as nil
script_data.restart = nil -- how to restart the (lib) script after it's been hidden - i.e. make it visible again

local gettext = dt.gettext
-- Define a function called _ to make the code more readable and have it call dgettext 
-- with the proper domain.
function _(msgid)
    -- underscore function
    -- translate message to local domain
    return gettext.dgettext("dxo_pureraw", msgid)
end

script_data.metadata = {
   name = "DxO_PureRAW",
   purpose = _"process images in DxO_PureRAW",
   author = "Fiona Boston <webmaster@fbphotography.uk>",
   help = "https://blog.fbphotography.uk/darktable/scripts/dxopureraw",
}

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
dt.print_log( "localedir: "..localedir )
gettext.bindtextdomain( 'DxO_pureRAW', localedir )



-- declare a local namespace and a couple of variables we'll need to install the module
local mE = {}
mE.event_registered = false  -- keep track of whether we've added an event callback or not
mE.module_installed = false  -- keep track of whether the module is module_installed


-- *************************************************
-- functions
-- *************************************************

local function sanitize_filename(filepath)
  local path = df.get_path(filepath)
  local basename = df.get_basename(filepath)
  local filetype = df.get_filetype(filepath)
  local sanitized = string.gsub(basename, " ", "\\ ")
  return path .. sanitized .. "." .. filetype
end


--removes spaces from the front and back of passed in text
local function clean_spaces(text)
  text = string.gsub(text,'^%s*','')
  text = string.gsub(text,'%s*$','')
  return text
end

local function save_preferences()
  dt.preferences.write( mod, 'group', 'bool', GUI.optionwidgets.group.value )
  dt.preferences.write( mod, 'copy_tags', 'bool', GUI.optionwidgets.copy_tags.value )
  dt.preferences.write( mod, 'copy_metadata', 'bool', GUI.optionwidgets.copy_metadata.value )
  dt.preferences.write( mod, 'add_tags', 'string', GUI.optionwidgets.add_tags.text )
end

local function load_preferences()
  GUI.optionwidgets.group.value = dt.preferences.read( mod, 'group', 'bool' )
  GUI.optionwidgets.copy_tags.value = dt.preferences.read( mod, 'copy_tags', 'bool')
  GUI.optionwidgets.copy_metadata.value = dt.preferences.read( mod, 'copy_metadata', 'bool')
  GUI.optionwidgets.add_tags.text = dt.preferences.read( mod, 'add_tags', 'string')
end

-- stop running export
local function stop_job( job )
  job.valid = false
end

-- main function
local function start_processing()
  local exported_images_table = {}
  dt.print_log( "starting DxO_pureRAW processing..." )

  save_preferences()

  -- create a new progress_bar displayed in darktable.gui.libs.backgroundjobs
  local job = dt.gui.create_job( _"Running DxO_pureRAW...", true, stop_job )

  local images = dt.gui.selection() --get selected images
  if #images < 1 then --ensure enough images selected
    dt.print(_('not enough images selected, select at least 1 image to process'))
    return
  end

  local img_table = {}
  local img_count = 0
  local img_list = ""
  local img_path = ""
 
    -- image list comprises raw file names of all images in selection
    -- also build list of expected images being exported by DXO Pureraw for later import

  for i,raw_img in pairs(images) do
    -- appeand this raw image to string of images to be sent to DxO_PureRAW
    img_list = img_list .. '"' ..  raw_img.path  .. os_path_seperator .. raw_img.filename .. '" '
      
    img_count = img_count + 1
    table.insert(img_table,raw_img)

  end

  -- stop job and remove progress_bar from ui, but only if not alreay canceled
  if(job.valid) then
    job.valid = false
  end

  job = dt.gui.create_job( _"Running DxO PureRAW...", true, stop_job )

  local DxO_cmd = df.sanitize_filename( dt.preferences.read( mod, "DxO_pureRAWExe", "string" ) )
  if dt.configuration.running_os == "macos" then
    if string.sub(DxO_cmd,-5) == ".app'" then
      -- user has entered .app folder rather than actual binary
      DxO_cmd = "open -W -a " .. DxO_cmd
    end
  end

  DxO_cmd = DxO_cmd .. " " .. img_list

  dt.print_log( 'commandline: '..DxO_cmd )

  local dxo_start_time = os.date("*t",os.time())
  dt.print_log( 'starting DxO_pureRAW at ' .. dxo_start_time.hour ..":" .. dxo_start_time.min .. ":" .. dxo_start_time.sec)
  local resp
  if dt.configuration.running_os == 'windows' then
    resp = dsys.windows_command( DxO_cmd )
  else
    resp = dsys.external_command( DxO_cmd )
  end
  
  if resp ~= 0 then
    dt.print_log( 'DxO_pureRAW returned '..tostring( resp ) )
    dt.print( _'could not start DxO_pureRAW application - is it set correctly in Lua Options?' )
    if(job.valid) then
      job.valid = false
    end
    return
  end
  
  local dxo_end_time = os.date("*t",os.time())
  dt.print_log("DxO Finihsed " .. dxo_end_time.hour ..":" .. dxo_end_time.min .. ":" .. dxo_end_time.sec)
  if(job.valid) then
    job.valid = false
  end

  local dxo_extensions = {}
  dxo_extensions={"_DxO_DeepPRIMEXD.dng","_DxO_DeepPRIME.dng","_DxO_DeepPRIMEXD.tif","_DxO_DeepPRIME.tif","_DxO_DeepPRIMEXD.jpg","_DxO_DeepPRIME.jpg"}
 
  for ii,this_raw_img in pairs(img_table) do
      
    dt.print_log("Post processing " .. this_raw_img.filename)

    -- test for existance of DXO images
    local img_type = string.sub(this_raw_img.filename,-3)
    local this_dxo_image_base = (df.chop_filetype(this_raw_img.path .. os_path_seperator .. this_raw_img.filename)) .. "-" .. img_type
    for jj = 1, 6 do
      local this_dxo_image = sanitize_filename(this_dxo_image_base .. dxo_extensions[jj])
      if df.check_if_file_exists(this_dxo_image) then
        dt.print_log("Found " ..  this_dxo_image)
        local imported_image = dt.database.import(this_dxo_image)
        -- images already in the database will have any sidecar files re-read 
        if imported_image == nil then
          dt.print_error("Failed to import " .. this_dxo_image)
        else
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
          
        end
      end
    end
   end



end




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


-- Preferences - locate DxO_PureRAW executable
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
        GUI.run

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
