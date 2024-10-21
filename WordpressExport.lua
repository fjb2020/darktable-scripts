--[[
    WordpressExport.lua - export images to Wordpress media library

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

]]





--[[ 

python example

def restImgUL(imgPath):
    url='http://xxxxxxxxxxxx.com/wp-json/wp/v2/media'
    data = open(imgPath, 'rb').read()
    fileName = os.path.basename(imgPath)
    res = requests.post(url='http://xxxxxxxxxxxxx.com/wp-json/wp/v2/media',
                        data=data,
                        headers={ 'Content-Type': 'image/jpg','Content-Disposition' : 'attachment; filename=%s'% fileName},
                        auth=('authname', 'authpass'))
    # pp = pprint.PrettyPrinter(indent=4) ## print it pretty. 
    # pp.pprint(res.json()) #this is nice when you need it
    newDict=res.json()
    newID= newDict.get('id')
    link = newDict.get('guid').get("rendered")
    print newID, link
    return (newID, link)
]]



