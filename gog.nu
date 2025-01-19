#!/usr/bin/env nu

let client_id = "46899977096215655"
let redirect_uri = "https://embed.gog.com/on_login_success?origin=client" | url encode
let client_secret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"

let token_path = $nu.home-path | path join .cache/gog.nu
let token_file = $token_path | path join .token.json

# get a login code for generating an auth token
def "main login" [] {
  let response_type = "code"
  let layout = "client2"

  print $'https://auth.gog.com/auth?client_id=($client_id)&redirect_uri=($redirect_uri)&response_type=($response_type)&layout=($layout)'
}

# generate a new auth token
def "main token new" [code: string] {
  mkdir $token_path
  http get --raw $'https://auth.gog.com/token?client_id=($client_id)&client_secret=($client_secret)&grant_type=authorization_code&code=($code)&redirect_uri=($redirect_uri)' | save -f $token_file
  chmod 600 $token_file
}

# refresh the auth token
def "main token refresh" [] {
  http get --raw $'https://auth.gog.com/token?client_id=($client_id)&client_secret=($client_secret)&grant_type=refresh_token&refresh_token=(open $token_file | get refresh_token)&redirect_uri=($redirect_uri)' | save -f $token_file
  chmod 600 $token_file
}

# search games
def "main search" [...search: string] {
  if not ($token_file | path exists) {
    main login
    main token new (input 'code=')
  }

  if ((date now) - (ls $token_file | get 0.modified)) > (open $token_file | get expires_in | into duration -u sec) {
    main token refresh
  }

  return (http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com/account/getFilteredProducts?mediaType=1&search=($search | str join " ")' | get products | select id title)
}

# download offline installers
def "main download" [
  ...search: string
  --id: string # install using the game id
  -n: int # install the nth game result
  --skip-linux # skip checking for linux files
  --patch # download latest patch file
  --patches # download all patch files
] {
  let gameid = if $id != null {
    $id
  } else {
    let results = main search ($search | str join ' ')

    if $n != null {
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

  for download in $response.downloads {
    if $download.0 == 'English' {
      let urls = if not $skip_linux and 'linux' in $download.1 {
        $download.1.linux
      } else if 'windows' in $download.1 {
        $download.1.windows
      } else {
        continue
      }
      let urls = if $patch {
        $urls | where manualUrl =~ 'patch[0-9]$' | get manualUrl | last
      } else if $patches {
        $urls | where manualUrl =~ 'patch[0-9]$' | get manualUrl
      } else {
        $urls | where manualUrl !~ 'patch[0-9]$' | get manualUrl
      }

      for url in $urls {
        print $'Downloading https://gog.com($url)'
        let location = http head --redirect-mode manual --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com($url)' | where name == "location" | get 0.value
        let filename = $location | url parse | get path | path basename
        if not ($filename | path exists) {
          let tmpfile = $'($filename).tmp'
          http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $location | save -fp $tmpfile
          mv -n $tmpfile $filename
        } else {
          print $'($filename) already exists. Skipping.'
        }
      }
    }
  }
}

# get the folder name for a setup file
def "main name" [file: string] {
  $file | str replace -ra '^(gog|setup)_|_v\d+_.*$|_\d+\-\d+_|_\d*\..*|_[12]\d{7}|_?\(.*\)|_?%\d+%\d{2}+|\.(bin|exe)$|_\d{1}[_.].*\.sh$' '' | str replace -a '_' '-' | str replace -ra '-+' '-'
}

# extract a gog installer with innoextract
def "main extract" [
  file: string
  --no-clean # Do not clean extracted files
] {
  if not ($file | path exists) {
    error make -u {msg: $'($file) does not exist!'}
  }

  let dir = main name $file
  innoextract -gmp --default-language en-US -d $dir $file
  if not $no_clean {
    main clean $dir
  }
}

def mv_support_files [d: string] {
  let dname = ($d | path split | skip 2 | path join)
  let found = (ls ./**/* | where type == dir | find -v __support | find -ir $'^($dname)$' | get name)
  let dest = if ($found | length) > 0 {
    $found.0
  } else {
    $'./($dname)'
  }
  for f in (ls $d) {
    if $f.type == file {
      mv -v $f.name $dest
    } else if $f.type == dir {
      let fname = ($f.name | path split | skip 2 | path join)
      let ffound = (ls $dest | where type == dir | find -ir $'^($fname)$' | get name)
      if ($ffound | length) == 0 {
        mv -v $f.name $dest
      } else {
        mv_support_files $f.name
      }
    }
  }
}

# fix extracted gog game files in a directory
def "main clean" [dir?: string] {
  if $dir != null {
    cd $dir
  }

  if ('app' | path exists) {
    mv app/* ./
    rm -rf app
  }
  rm -rf *EULA*.DOC* *EULA*.doc* Customer_support.htm DOSBOX LICENSE.DOC Support.ico __redist cloud_saves commonappdata dosbox*conf gfw_high*.ico gog.ico goggame-*.* goglog.ini support.ico webcache.zip

  if ('__support/app' | path exists) {
    rm -f __support/app/dosbox*.conf
    mv_support_files __support/app
  }
  if ('__support/save' | path exists) {
    mv_support_files __support/save
  }
  rm -rf __support DOSBox
}

def main [] {
  nu $env.CURRENT_FILE --help
}
