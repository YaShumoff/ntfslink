{-----------------------------------------------------------------------------
The contents of this file are subject to the GNU General Public License
Version 1.1 or later (the "License"); you may not use this file except in
compliance with the License. You may obtain a copy of the License at
http://www.gnu.org/copyleft/gpl.html

Software distributed under the License is distributed on an "AS IS" basis,
WITHOUT WARRANTY OF ANY KIND, either expressed or implied. See the License for
the specific language governing rights and limitations under the License.

The Initial Developer of the Original Code is Michael Elsd�rfer.
All Rights Reserved.

You may retrieve the latest version of this file at the NTFS Link Homepage
located at http://www.elsdoerfer.net/ntfslink/

Known Issues:
-----------------------------------------------------------------------------}

unit Global;

interface

uses
  SysUtils, Windows, JclRegistry;

const
  // Paths used in registry
  NTFSLINK_REGISTRY = 'Software\elsdoerfer.net\NTFS Link\';
  NTFSLINK_CONFIGURATION = NTFSLINK_REGISTRY + 'Config\';

  // Junction Tracking: Define where the data should be stored
  NTFSLINK_TRACKINGDATA_KEY = NTFSLINK_REGISTRY + 'Tracking\';
  NTFSLINK_TRACKING_STREAM = 'ntfslink.junction-tracking';

  // Some default values, can (mostly) be overridden by configuration values
  OVERLAY_HARDLINK_ICONINDEX = 0;
  OVERLAY_JUNCTION_ICONINDEX = 1;
  OVERLAY_PRIORITY_DEFAULT = 50;
  // Template used to name the created links; can be overridden by lang file
  LINK_PREFIX_TEMPLATE_DEFAULT =  'Link%s to %s';
  COPY_PREFIX_TEMPLATE_DEFAULT =  'Copy%s of %s';

var
  // Handles to various glyphs used in shell menus; initialized at startup;
  GLYPH_HANDLE_STD: HBITMAP;
  GLYPH_HANDLE_JUNCTION: HBITMAP;
  GLYPH_HANDLE_LINKDEL: HBITMAP;
  GLYPH_HANDLE_EXPLORER: HBITMAP;


// Make certain registry entries to make sure the extension also works for
// non-Admin accounts with restricted rights.
procedure ApproveExtension(ClassIDStr, Description: string);

// Will add a backslash to the end of the passed string, if not yet existing
function CheckBackslash(AFileName: string): string;
// Exactly the opposite: removes the backslash, if it is there
function RemoveBackslash(AFileName: string): string;

// Return the name of the file/directory to create. This depends on the
// existing files/directories, i.e. if the user creates multiple links
// of the same file, we will enumerate them: Copy(1), Copy(2), etc..
function GetLinkFileName(Source, TargetDir: string; Directory: boolean;
  PrefixTemplate: string = LINK_PREFIX_TEMPLATE_DEFAULT): string;

// Internal function used to create hardlinks
procedure InternalCreateHardlink(Source, Destination: string);
// Calls the one above, but catches all exceptions and returns a boolean
function InternalCreateHardlinkSafe(Source, Destination: string): boolean;

// Interal functions used to create junctions; The Base-function actually creates
// the junctions using a final directory name, the other one first generates
// the directory name based on a template and a base name (e.g. does the
// "Link (x) of..."), and then calls InternalCreateJunctionEx()
function InternalCreateJunctionBase(LinkTarget, Junction: string): boolean;
function InternalCreateJunction(LinkTarget, Junction: string;
  TargetDirName: string = '';  
  PrefixTemplate: string = LINK_PREFIX_TEMPLATE_DEFAULT): boolean;

// Wrapper around NtfsGetJunctionPointDestination(), passing the
// destination as the result, not as a var parameter; In addition, fix some
// issues with the result value of the JCL function, e.g. remove \\?\ prefix.
function GetJPDestination(Folder: string): string;  

implementation

uses
  ShlObj, JclNTFS, GNUGetText, JunctionMonitor;

// ************************************************************************** //

function CheckBackslash(AFileName: string): string;
begin
  if (AFileName <> '') and (AFileName[length(AFileName)] <> '\') then
    Result := AFileName + '\'
  else Result := AFileName;
end;

function RemoveBackslash(AFileName: string): string;
begin
  if (AFileName <> '') and (AFileName[length(AFileName)] = '\') then
    Result := Copy(AFileName, 1, length(AFileName) - 1)
  else Result := AFileName;
end;

// ************************************************************************** //

function GetLinkFileName(Source, TargetDir: string; Directory: boolean;
  PrefixTemplate: string = LINK_PREFIX_TEMPLATE_DEFAULT): string;
var
  x: integer;
  SrcFile: string;
  LinkStr, NumStr: string;
begin
  // Get the filename part of the source path. If the source path is a drive,
  // then use the drive letter.
  SrcFile := ExtractFileName(RemoveBackslash(Source));
  if SrcFile = '' then SrcFile := 'Drive ' + ExtractFileDrive(Source)[1];

  // Loop until we finally find a filename not yet in use
  x := 0;
  repeat
    Inc(x);

    // Try to get the translated Format-template for the filename
    LinkStr := _(PrefixTemplate);
    // The very first link does not get a number
    if x > 1 then NumStr := ' (' + IntToStr(x) + ')' else NumStr := '';

    // Format the template and use the result as our filename. As the
    // translated template might be invalid, the Format() call might
    // fail. If this is the case, we catch the exception and use
    // the default template.
    try
      Result := CheckBackslash(TargetDir) + Format(LinkStr, [NumStr, SrcFile]);
    except
      Result := CheckBackslash(TargetDir) + Format(PrefixTemplate, [NumStr, SrcFile]);
    end;
  until ((Directory) and (not DirectoryExists(Result))) or
        ((not Directory) and (not FileExists(Result)));

  // Directories/Junctions require a trailing backslash
  if Directory then
    Result := CheckBackslash(Result);
end;

// ************************************************************************** //

procedure ApproveExtension(ClassIDStr, Description: string);
begin
  if (Win32Platform = VER_PLATFORM_WIN32_NT) then
    RegWriteString(HKEY_LOCAL_MACHINE,
       'SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved',
       ClassIDStr, Description);
end;

// ************************************************************************** //

procedure InternalCreateHardlink(Source, Destination: string);
var
  NewFileName: string;
begin
  NewFileName := GetLinkFileName(Source, Destination, False);
  if not NtfsCreateHardLink(NewFileName, PAnsiChar(Source)) then
    raise Exception.Create('NtfsCreateHardLink() failed.');

  // TODO [future] Would be great, if position of the links is automatically
  // set to where the user dropped the source file.
  SHChangeNotify(SHCNE_CREATE, SHCNF_PATH, PAnsiChar(NewFileName), nil);
  SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATH, PAnsiChar(Source), nil);
end;

function InternalCreateHardlinkSafe(Source, Destination: string): boolean;
begin
  try
    InternalCreateHardlink(Source, Destination);
    Result := True;
  except
    Result := False;
  end;
end;

// ************************************************************************** //

function InternalCreateJunctionBase(LinkTarget, Junction: string): boolean;
begin
  // Create an empty directory first; note that we continue, if the directory
  // already exists, because this is required when the ContextMenu hook wants
  // to make a junction based on an existing, empty folder.
  Result := CreateDir(Junction) or DirectoryExists(Junction);
  // If successful, then try to make a junction
  if Result then
  begin
    Result := NtfsCreateJunctionPoint(CheckBackslash(Junction), LinkTarget);
    // if junction creation was unsuccessful, delete created directory  
    if not Result then
      RemoveDir(Junction)
    // otherwise (junction successful created): store the information about the
    // new junction, so that we can later find out about how many junctions are
    // pointing to a certain directory.
    else
      TrackJunctionCreate(Junction, LinkTarget);

    // Notify explorer of the change
    SHChangeNotify(SHCNE_CREATE, SHCNF_PATH, PAnsiChar(Junction), nil);
  end;
end;

function InternalCreateJunction(LinkTarget, Junction: string;
  TargetDirName: string = '';  // see inline comment
  PrefixTemplate: string = LINK_PREFIX_TEMPLATE_DEFAULT): boolean;
var
  NewDir: string;
begin
  // Calculate name of directory to create
  if TargetDirName <> '' then
    // The TargetFileName parameter was added, because this function is
    // called in two different situations. For one, from the DragDrop Hook,
    // were we simply have the source directory we want to link to, and the
    // target directory we want to create the junction in. The second situation
    // is the call from the CopyHook, were we need the directory to link to,
    // the directory were to create the junction, /and/ in addition the
    // filename to use as a template for the junction filename. In the first
    // case, this template filename is identical with the filename of the
    // directory to link to, in the second this is not the case. Therefore,
    // a new parameter, TargetFileName, was added, which will be used as a
    // template. In the second case, we can use "Junction" for that.
    NewDir := GetLinkFileName(TargetDirName, Junction, True, PrefixTemplate)
  else
    NewDir := GetLinkFileName(LinkTarget, Junction, True, PrefixTemplate);

  // Call the sibling function which creates the hardlink, but which takes
  // the final filename of the junction as a parameter
  Result := InternalCreateJunctionBase(LinkTarget, NewDir);
end;

// ************************************************************************** //

function GetJPDestination(Folder: string): string;
begin
  NtfsGetJunctionPointDestination(Folder, Result);
  // Bug in JCL? There is always a #0 appended..
  if (Result[Length(Result)]) = #0 then
    Delete(Result, Length(Result), 1);
  Result := CheckBackslash(Result);
  // Remove the \\?\ if existing
  if Pos('\??\', Result) = 1 then
    Delete(Result, 1, 4);
end;

end.
