#!/bin/bash

 if [[ -z $1 ]] ; then
   echo -e "Usage: ./sec.sh 8.5.1 8.4.6 7.58"
   echo -e "(List the releases that will be tagged.)"
   exit 1
 fi


# @param $1
#   Replacement pattern
# @param $2
#   File path.
function portable_sed() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' -e "$1" "$2"
  else
    sed -i -e "$1" "$2"
  fi
}

# @param $1
#   Version string.
function validate_version() {

  # We only support D7 through D9 for now.
  # Kind of a Y2K bug for Drupal versions.
  re="^[ ]*([7-9])\.([0-9][0-9]*)(\.([1-9][0-9]*))?[ ]*$"

  message="\n$1 can't be tagged automatically. To use $1, tag the release manually."

  if [[ ! $1 =~ $re ]] ; then
    echo -e "$message"
    echo -e "The regex does not match."
    exit 1
  fi

  # D7 must only have major.patch.
  if [[ ${BASH_REMATCH[1]} = 7 ]] ; then
    if [[ ! -z ${BASH_REMATCH[4]} ]] ; then
        echo -e "$message"
	echo -e "The Drupal 7 version should not be semver."
      exit 1
    fi
  else
    # Later branches must have major.minor.patch.
    if [[ -z ${BASH_REMATCH[4]} ]] ; then
      echo -e "$message"
      echo -e "The Drupal 8 or 9 version must be semver."
      exit 1
    fi
  fi
}

# @param $1
#   The major branch.
function includes_file() {

  includes_file=''

  if [[ $1 = 7 ]] ; then
    includes_file="includes/bootstrap.inc"
  else
    includes_file="core/lib/Drupal.php"
  fi
}

# @param $1
#   The Drupal 7 version.
# @param $2
#   The old version constant.
# @param $3
#   Whether to remove the 'development version' lines.
function insert_changelog_entry() {
  # This assumes the D7 changelog location, because D8 does not maintain a
  # list of releases in a changelog.
  find="Drupal $2, "
  date=$(date +"%Y-%m-%d")
  changelog="Drupal $1, $date\\
-----------------------\\
- Fixed security issues:\\
"
  # @todo This is relying on a global.
  for advisory in "${advisories[@]}" ; do
    changelog="$changelog   - $advisory\\
"
  done
  changelog="$changelog\\
$find"

  grep -q "$find" CHANGELOG.txt
  if [ ! $? -eq 0 ] ; then
    echo -e "Cannot match version constant $2 in the CHANGELOG. The CHANGELOG must be corrected manually."
    exit 1
  fi
  portable_sed "s/$find/$changelog/1" "CHANGELOG.txt"

  if [ "$3" = true ] ; then
    dev="Drupal 7.xx, xxxx-xx-xx \(development version\)
-----------------------
\n"
    perl -i -p0e "s/$dev//g" CHANGELOG.txt
  fi
}

# @param $1
#   The version constant to use.
# @param $2
#   The old version constant.
# @param $3
#   The major version.
function update_constant() {
  # Update the version constant.

  includes_file "$3"

  find=''
  replace=''
  if [[ "$3" = 7 ]] ; then
    find="'VERSION', '$2'"
    replace="'VERSION', '$1'"

  else
    find="VERSION = '$2'"
    replace="VERSION = '$1'"
  fi

  grep -q "$find" "$includes_file"
  if [ ! $? -eq 0 ] ; then
    echo -e "Cannot match version constant $2. The release must be tagged manually."
    exit 1
  fi
  portable_sed "s/$find/$replace/1" "$includes_file"
}


# @param $1
#   The Drupal version to set.
# @param $2
#   The previous version.
# @param $3
#   The major version.
# @param $4
#   The minor version.
function set_version() {
  if [[ $3 -ge 9 && $4 -gt 0 ]] ; then
    echo -e "\n\n Setting version with Composer for 9.1+ \n"
    php -r "include 'vendor/autoload.php'; \Drupal\Composer\Composer::setDrupalVersion('.', '$1');"
  else
    update_constant $1 $2 $3
  fi
}

versions=( "$@" )

echo -e "Enter the remote name (blank for origin):"
read remote

if [ -z $remote ] ; then
  remote='origin'
fi

echo -e "How many advisories will be included in the release?"
read advisory_count

echo -e "First SA number in this release (e.g. '3' if SA-CORE-2019-003 is next):"
read first_advisory

year=$(date +%Y)
declare -a advisories
declare -a advisory_contributors

for i in $( eval echo {1..$advisory_count} )
do
  advisory_number=$(( $i + $first_advisory - 1 ))
  advisory_name=$(printf '%03d' $advisory_number)
  advisories[$i]="SA-CORE-$year-$advisory_name"
done

for sa in "${!advisories[@]}"
do
  # @todo soet it so the oldest tag/branch is first.
  declare -a base
  declare -a major
  declare -a minor
  declare -a branches
  declare -a previous
  declare -a next

  echo -e "\n\n==== ${advisories[$sa]} ===="

  for i in "${!versions[@]}"; do
    v="${versions[$i]}"

    validate_version "$v" || ! $? -eq 0

    if [[ -z ${BASH_REMATCH[4]} ]] ; then
      major[$i]="${BASH_REMATCH[1]}"
      base[$i]="${BASH_REMATCH[1]}"
      previous[$i]="${base[$i]}.$(( ${BASH_REMATCH[2]} - 1 ))"
      next[$i]="${base[$i]}.$(( ${BASH_REMATCH[2]} + 1 ))"
    else
      major[$i]="${BASH_REMATCH[1]}"
      minor[$i]="${BASH_REMATCH[2]}"
      base[$i]="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
      previous[$i]="${base[$i]}.$(( ${BASH_REMATCH[4]} - 1 ))"
      next[$i]="${base[$i]}.$(( ${BASH_REMATCH[4]} + 1 ))"
    fi

    branches[$i]="${base[$i]}.x"

    patch=''
    if [[ $i -eq 0 ]]; then
      echo -e "\nPath to the ${branches[$i]} patch for ${advisories[$sa]} (tab completion works but not '~'):"
      read -e patch

      # This will be empty on the first pass because it is initialized above.
      # Thereafter it will be whatever was entered for the last branch (based
      # on input order, not version order).
      if [ -z $patch ] ; then
        echo -e "\nYou must specify at least one patch name:"
        read -e patch
      fi
    else
      echo -e "\nPath to the ${branches[$i]} patch for ${advisories[$sa]} (blank to use the last patch):"
      read -e patch
    fi

    if [[ -s "$patch" ]] ; then
      # Use indirect expansion, because bash 3 doesn't support associative
      # arrays.
      declare patches_${sa}_${i}="$patch"
    else
      if [[ -z "$patch" ]] ; then
        last_index=$(( $i - 1 ))
        last_patch=patches_${sa}_${last_index}
        declare patches_${sa}_${i}=${!last_patch}
      else
        echo -e "\nNo valid filename was supplied."
        exit 1
      fi
    fi
  done

  echo -e "\nEnter the list of contributors for ${advisories[$sa]}, separated by commas (blank for none):"
  read -e contributors
  advisory_contributors[$sa]=$contributors
done

  echo -e "\n\n==== Beginning tagging ====\n"

# Loop over version list.
for i in "${!versions[@]}"; do
  version="${versions[$i]}"
  p="${previous[$i]}"
  n="${next[$i]}"
  branch="${branches[$i]}"
  includes_file "${major[$i]}" || ! $? -eq 0

  git checkout -b "$version"-security "$p"
  if [ ! $? -eq 0 ] ; then
    echo -e "Error: Could not create a working branch."
    exit 1
  fi

  echo -e "\nWorking branch created.\n"
  for sa in "${!advisories[@]}"; do
    varname=patches_${sa}_${i}
    f=${!varname}

    echo -e "\nAttempting to apply patch $f...\n"

    # Check that the patch doesn't update Drupal.php or bootstrap.inc,
    # because our strategy for resolving the version constant merge
    # conflict won't work.
#    grep_output="$(grep $includes_file $patch)"
#    echo -e "\nPast the grep call...\n"

#    if [ ! -z "$grep_output" ] ; then
#      echo -e "The $v patch includes changes to $includes_file. $v must be tagged manually."
#      exit 1
#    fi

    echo -e "\nPast the grep exit condition...\n"

    git apply --index "$f"

    if [ ! $? -eq 0 ] ; then
      echo -e "Error: Could not apply the specified patch $f."
      exit 1
    fi

    # Prepare the commit message
    commit_message="${advisories[$sa]}"
    if [ ! -z "${advisory_contributors[$sa]}" ] ; then
      commit_message="$commit_message by ${advisory_contributors[$sa]}"
    fi

    git commit -am "$commit_message" --no-verify
  done

  # If we're on D8 or higher, perform a clean Composer install.
  if [[ "${major[$i]}" > 7 ]] ; then
    rm -rf vendor
    composer install --no-progress --no-suggest -n -q
  fi

  # Update the version constant.
  set_version "$version" "$p" "${major[$i]}" "${minor[$i]}"

  # Only D7 uses a changelog now.
  if [[ "${major[$i]}" = 7 ]] ; then
    insert_changelog_entry "$version" "$p" true
    git add CHANGELOG.txt
  # D8 and higher need to have the lock file updated prior to tagging.
  else
    echo -e "\nUpdating metapackage versions and lock file to ${version}...\n"
    COMPOSER_ROOT_VERSION="$version" composer update drupal/core*
  fi

  echo -e "\nTagging ${version}...\n"

  git commit -am "Drupal $version" --no-verify
  git tag -a "$version" -m "Drupal $version"

  # Merge the changes back into the main branch.
  git checkout "$branch"

  # We expect a merge conflict here.
  # @todo Following https://www.drupal.org/project/drupal/issues/3090906 there
  #   will be additional merge conflicts to resolve here.
  git merge --no-ff "$version" 1> /dev/null

  # Fix it by checking out the HEAD version and updating that.
  git checkout HEAD -- "$includes_file"

  # For D7 only, merge the changelog entry into HEAD manually.
  if [[ "${major[$i]}" = 7 ]] ; then
    git checkout HEAD -- CHANGELOG.txt
    insert_changelog_entry "$version" "$p" false
    git add CHANGELOG.txt
  # For D8 and higher, fix up the lock file again.
  else
    git checkout HEAD -- composer.lock
    echo -e "\nRe-updating metapackage versions and lock file for the dev branch...\n"

    devbranch="$branch""-dev"
    COMPOSER_ROOT_VERSION="$devbranch" composer update drupal/core*
  fi

  git commit -am "Merged $version." --no-verify
  set_version "$n-dev" "$version-dev" "${major[$i]}" "${minor[$i]}"
  git add "$includes_file"
  git commit -am "Back to dev." --no-verify

  git branch -D "$version"-security
done

branch_list=$(IFS=' ' ; echo ${branches[*]})
tag_list=$(IFS=' ' ; echo ${versions[*]})

echo -e "To push use:\n\n"
echo -e "git push $remote $tag_list"
echo -e "\nCreate the release notes to begin packaging."
echo -e "Once the release nodes have tarballs, then push the full branch data:"
echo -e "\ngit push $remote $branch_list"
echo -e "\n"
