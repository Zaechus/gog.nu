#!/usr/bin/env nu

const client_id = "46899977096215655"
const client_secret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
let redirect_uri = "https://embed.gog.com/on_login_success?origin=client" | url encode

let token_path = $nu.home-dir | path join .cache/gog.nu
let token_file = $token_path | path join .token.json

# Get a login code for generating an auth token
def "main login" [] {
  let response_type = "code"
  let layout = "client2"

  print $'https://auth.gog.com/auth?client_id=($client_id)&redirect_uri=($redirect_uri)&response_type=($response_type)&layout=($layout)'
}

# Generate a new auth token
def "main token new" [code: string] {
  mkdir $token_path
  http get --raw $'https://auth.gog.com/token?client_id=($client_id)&client_secret=($client_secret)&grant_type=authorization_code&code=($code)&redirect_uri=($redirect_uri)' | save -f $token_file
  chmod 600 $token_file
}

# Refresh the auth token
def "main token refresh" [] {
  http get --raw $'https://auth.gog.com/token?client_id=($client_id)&client_secret=($client_secret)&grant_type=refresh_token&refresh_token=(open $token_file | get refresh_token)&redirect_uri=($redirect_uri)' | save -f $token_file
  chmod 600 $token_file
}

# Search games
def "main search" [...search: string] {
  if not ($token_file | path exists) {
    main login
    main token new (input 'code=')
  }

  if ((date now) - (ls $token_file | get 0.modified)) > (open $token_file | get expires_in | into duration -u sec) {
    main token refresh
  }

  return (http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com/account/getFilteredProducts?mediaType=1&search=($search | str join " " | url encode)' | get products | select id title)
}

# Show information and downloads for a gameid
def "main show" [gameid: string] {
  return (http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com/account/gameDetails/($gameid).json' | select title cdKey cdKeys downloads extras dlcs)
}

# Show DLCs for a gameid, if any
def "main dlcs" [gameid: string] {
  return (http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com/account/gameDetails/($gameid).json' | get dlcs | select title cdKey cdKeys downloads extras dlcs)
}

# Download offline installers
def "main download" [
  ...search: string
  -n: int # Install the nth game result
  --extras: range # Download a range of extras files instead
  --dlc: string = 'none' # Download `'all'` content or `'only'` DLC content
  --patch # Download all patch files
  --skip-linux # Skip checking for linux files
] {
  let gameid = if ($search | first | default "") =~ '\d{10,}' {
    $search.0
  } else {
    let results = main search ...$search

    if $n != null {
      print $'Downloading `($results.title | get $n)`...'
      $results.id | get $n
    } else if ($results | length) > 1 {
      return $results
    } else if ($results | length) == 0 {
      return "No matches."
    } else {
      $results.0.id
    }
  }

  let response = http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com/account/gameDetails/($gameid).json'

  let urls = if ($extras | describe) == range {
    let extras = $response.extras | slice $extras
    print ($extras | select name type size)
    $extras.manualUrl
  } else {
    let downloads = match $dlc {
      'all' => { $response.downloads | union ($response.dlcs | each {|dlc| $dlc.downloads} | flatten) },
      'only' => { $response.dlcs | each {|dlc| $dlc.downloads} | flatten },
      _ => { $response.downloads }
    }
    $downloads | where {|x| $x.0 == 'English'} | each {|x|
      if not $skip_linux and 'linux' in $x.1 {
        $x.1.linux.manualUrl
      } else if 'windows' in $x.1 {
        $x.1.windows.manualUrl
      } else {
        ignore
      }
    } | flatten | where {|x|
      if $patch {
        $x =~ 'patch[0-9]$'
      } else {
        $x !~ 'patch[0-9]$'
      }
    }
  }

  for url in $urls {
    print $'Downloading https://gog.com($url)'
    let location = http head --redirect-mode manual --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com($url)' | where name == "location" | get 0.value
    let filename = $location | url decode | url parse | get path | path basename
    if not ($filename | path exists) {
      let tmpfile = $'($filename).tmp'
      http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $location | save -fp $tmpfile
      mv -n $tmpfile $filename
    } else {
      print $'($filename) already exists. Skipping.'
    }
  }
}

# Generate an approximate folder name for a setup file
def "main name" [file: string] {
  $file | str lowercase
    | str replace -ra '^(gog|patch|setup)_' ''
    | str replace -ra '_cut_.*' '_cut'
    | str replace -ra '_en_.*' ''
    | str replace -ra '_gog(_|-).*' ''
    | str replace -ra '(_\d+)+(_\d+\w*){2,}(_|\.).*' ''
    | str replace -ra '_v\d+.*' ''
    | str replace -ra '_\d{3,}.*' ''
    | str replace -ra '_?(\d+)?\..*' ''
    | str replace -ra '\(|\)' ''
    | str replace -a '_s_' 's_'
    | str replace -a 'tm_' '_'
    | str replace -a '_' '-'
    | str replace -ra '-+' '-'
}

# Extract a gog installer with innoextract
def "main extract" [
  file: string
  --no-clean (-n) # Do not clean extracted files
] {
  if not ($file | path exists) {
    error make -u {msg: $'($file) does not exist!'}
  }

  let dir = main name $file
  if $no_clean {
    innoextract -gm --default-language en-US -d $dir $file
  } else {
    innoextract -Lgm --default-language en-US -d $dir $file
    main clean $dir
  }
}

# Fix extracted gog game files in a directory
#
# Mostly useful for DOS games. Might have issues in a Windows game installation or when innoextract is used without the lowercase flag.
def "main clean" [dir?: string] {
  if $dir != null {
    cd $dir
  }

  # fixes games like Quake where everything including __support is inside a single 'app' folder
  if (ls | length) == (ls | where name == app | length) {
    mv app/* ./
    rm app
  }

  # some DOS games like Dungeon Keeper have essential files in 'app' and '__support/save'
  let orphans = if ('__support' | path exists) {
    ls | where name == app | union (ls __support)
  } else {
    ls | where name == app
  }
  for d in $orphans {
    if (ls $d.name | is-empty) {
      rm -rfv $d.name
      continue
    }
    ls ($d.name)/**/* | sort-by name | each {|f|
      let newpath = $f.name | str replace $'($d.name)/' ''
      if $f.type == dir {
        mkdir -v $newpath
      } else {
        mv -uv $f.name $newpath
      }
    }
  }

  # remove the garbage but only for DOS games
  if (ls | where ($it.name | str starts-with -i 'dosbox') | length) > 0 {
    rm -rfv DOSBOX DOSBox GameuxInstallHelper.dll Support.ico __redist __support app cloud_saves commonappdata customer_support.htm dosbox* gameuxinstallhelper.dll gfw_high*.ico gog.ico goggame-* goggame.dll support.ico webcache.zip
  } else {
    rm -rfv EULA.txt webcache.zip
  }
}

def main [] {
  nu $env.CURRENT_FILE --help
}
