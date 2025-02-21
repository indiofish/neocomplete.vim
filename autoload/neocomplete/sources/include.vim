"=============================================================================
" FILE: include.vim
" AUTHOR:  Shougo Matsushita <Shougo.Matsu@gmail.com>
" License: MIT license  {{{
"     Permission is hereby granted, free of charge, to any person obtaining
"     a copy of this software and associated documentation files (the
"     "Software"), to deal in the Software without restriction, including
"     without limitation the rights to use, copy, modify, merge, publish,
"     distribute, sublicense, and/or sell copies of the Software, and to
"     permit persons to whom the Software is furnished to do so, subject to
"     the following conditions:
"
"     The above copyright notice and this permission notice shall be included
"     in all copies or substantial portions of the Software.
"
"     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
"     OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
"     MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
"     IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
"     CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
"     TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
"     SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
" }}}
"=============================================================================

let s:save_cpo = &cpo
set cpo&vim

" Global options definition. "{{{
let g:neocomplete#sources#include#max_processes =
      \ get(g:, 'neocomplete#sources#include#max_processes', 20)
"}}}

let s:source = {
      \ 'name' : 'include',
      \ 'kind' : 'keyword',
      \ 'mark' : '[I]',
      \ 'rank' : 8,
      \ 'hooks' : {},
      \}

function! neocomplete#sources#include#define() "{{{
  return neocomplete#has_vimproc() ? s:source : {}
endfunction"}}}

function! s:source.hooks.on_init(context) "{{{
  call s:initialize_variables()
  call neoinclude#initialize()

  augroup neocomplete
    autocmd BufWritePost * call s:check_buffer('', 0)
    autocmd CursorHold * call s:check_cache()
  augroup END

  " Create cache directory.
  call neocomplete#cache#make_directory('include_cache')
endfunction"}}}

function! s:source.hooks.on_final(context) "{{{
  silent! delcommand NeoCompleteIncludeMakeCache
endfunction"}}}

function! s:source.gather_candidates(context) "{{{
  if neocomplete#within_comment()
    return []
  endif

  if !has_key(s:include_info, bufnr('%'))
    " Make cache automatically.
    call s:check_buffer('', 0)
  endif

  let keyword_list = []

  " Make cache automatically.
  for include in s:include_info[bufnr('%')].include_files
    call neocomplete#cache#check_cache(
          \ 'include_cache', include,
          \ s:async_include_cache, s:include_cache, 0)
    if has_key(s:include_cache, include)
      let s:cache_accessed_time[include] = localtime()
      let keyword_list += s:include_cache[include]
    endif
  endfor

  return keyword_list
endfunction"}}}

function! neocomplete#sources#include#initialize() "{{{
  call neoinclude#initialize()
endfunction"}}}

function! neocomplete#sources#include#get_include_files(bufnumber) "{{{
  if has_key(s:include_info, a:bufnumber)
    return copy(s:include_info[a:bufnumber].include_files)
  else
    return s:get_buffer_include_files(a:bufnumber)
  endif
endfunction"}}}

" For Debug.
function! neocomplete#sources#include#get_current_include_files() "{{{
  return s:get_buffer_include_files(bufnr('%'))
endfunction"}}}

function! s:check_buffer(bufnumber, is_force) "{{{
  if !neocomplete#helper#is_enabled_source('include',
        \ neocomplete#get_context_filetype())
    return
  endif

  let bufnumber = (a:bufnumber == '') ? bufnr('%') : a:bufnumber
  let filename = fnamemodify(bufname(bufnumber), ':p')

  if !has_key(s:include_info, bufnumber)
    " Initialize.
    let s:include_info[bufnumber] = {
          \ 'include_files' : [], 'lines' : [],
          \ 'async_files' : {},
          \ }
  endif

  let include_info = s:include_info[bufnumber]

  if a:is_force || include_info.lines !=# getbufline(bufnumber, 1, 100)
    let include_info.lines = getbufline(bufnumber, 1, 100)

    " Check include files contained bufname.
    let include_files = s:get_buffer_include_files(bufnumber)

    " Check include files from function.
    let filetype = getbufvar(a:bufnumber, '&filetype')
    let function = neoinclude#get_function(filetype)
    if function != '' && getbufvar(bufnumber, '&buftype') !~ 'nofile'
      let path = neoinclude#get_path(a:bufnumber, filetype)
      let include_files += call(function,
            \ [getbufline(bufnumber, 1, (a:is_force ? '$' : 1000)), path])
    endif

    if getbufvar(bufnumber, '&buftype') !~ 'nofile'
          \ && filereadable(filename)
      call add(include_files, filename)
    endif
    let include_info.include_files = neocomplete#util#uniq(include_files)
  endif

  if g:neocomplete#sources#include#max_processes <= 0
        \ || !executable(g:neocomplete#ctags_command)
    return
  endif

  let filetype = getbufvar(bufnumber, '&filetype')
  if filetype == ''
    let filetype = 'nothing'
  endif

  for filename in include_info.include_files
    if (a:is_force || !has_key(include_info.async_files, filename))
          \ && !has_key(s:include_cache, filename)
      if !a:is_force && has_key(s:async_include_cache, filename)
            \ && len(s:async_include_cache[filename])
            \            >= g:neocomplete#sources#include#max_processes
        break
      endif

      let s:async_include_cache[filename]
            \ = [ s:initialize_include(filename, filetype) ]
      let include_info.async_files[filename] = 1
    endif
  endfor
endfunction"}}}

function! s:get_buffer_include_files(bufnumber) "{{{
  let filetype = getbufvar(a:bufnumber, '&filetype')
  if filetype == ''
    return []
  endif

  call neoinclude#set_filetype_paths(a:bufnumber, filetype)

  let pattern = neoinclude#get_pattern(a:bufnumber, filetype)
  if pattern == ''
    return []
  endif
  let path = neoinclude#get_path(a:bufnumber, filetype)
  let expr = neoinclude#get_expr(a:bufnumber, filetype)
  let suffixes = &l:suffixesadd

  " Change current directory.
  let cwd_save = getcwd()
  let buffer_dir = fnamemodify(bufname(a:bufnumber), ':p:h')
  if isdirectory(buffer_dir)
    execute 'lcd' fnameescape(buffer_dir)
  endif

  let include_files = s:get_include_files(0,
        \ getbufline(a:bufnumber, 1, 100), filetype, pattern, path, expr)

  if isdirectory(buffer_dir)
    execute 'lcd' fnameescape(cwd_save)
  endif

  " Restore option.
  let &l:suffixesadd = suffixes

  return neocomplete#util#uniq(include_files)
endfunction"}}}
function! s:get_include_files(nestlevel, lines, filetype, pattern, path, expr) "{{{
  let include_files = []
  for line in a:lines "{{{
    if line =~ a:pattern
      let match_end = matchend(line, a:pattern)
      if a:expr != ''
        let eval = substitute(a:expr, 'v:fname',
              \ string(matchstr(line[match_end :], '\f\+')), 'g')
        let filename = fnamemodify(findfile(eval(eval), a:path), ':p')
      else
        let filename = fnamemodify(findfile(
              \ matchstr(line[match_end :], '\f\+'), a:path), ':p')
      endif

      if filereadable(filename)
        call add(include_files, filename)

        if a:nestlevel < 1
          " Nested include files.
          let include_files += s:get_include_files(
                \ a:nestlevel + 1, readfile(filename)[:100],
                \ a:filetype, a:pattern, a:path, a:expr)
        endif
      elseif isdirectory(filename) && a:filetype ==# 'java'
        " For Java import with *.
        " Ex: import lejos.nxt.*
        let include_files +=
              \ neocomplete#util#glob(filename . '/*.java')
      endif
    endif
  endfor"}}}

  return include_files
endfunction"}}}

function! s:check_cache() "{{{
  if !neocomplete#helper#is_enabled_source('include',
        \ neocomplete#get_context_filetype())
    return
  endif

  let release_accessd_time = localtime() - g:neocomplete#release_cache_time

  for key in keys(s:include_cache)
    if has_key(s:cache_accessed_time, key)
          \ && s:cache_accessed_time[key] < release_accessd_time
      call remove(s:include_cache, key)
    endif
  endfor
endfunction"}}}

function! s:initialize_include(filename, filetype) "{{{
  " Initialize include list from tags.
  return {
        \ 'filename' : a:filename,
        \ 'cachename' : neocomplete#cache#async_load_from_tags(
        \         'include_cache', a:filename, a:filetype,
        \         neocomplete#get_keyword_pattern(a:filetype, s:source.name),
        \         s:source.mark, 1)
        \ }
endfunction"}}}
function! neocomplete#sources#include#make_cache(bufname) "{{{
  if !neocomplete#is_enabled()
    call neocomplete#initialize()
  endif

  let bufnumber = (a:bufname == '') ? bufnr('%') : bufnr(a:bufname)
  if has_key(s:async_include_cache, bufnumber)
        \ && filereadable(s:async_include_cache[bufnumber].cache_name)
    " Delete old cache.
    call delete(s:async_include_cache[bufnumber].cache_name)
  endif

  " Initialize.
  if has_key(s:include_info, bufnumber)
    call remove(s:include_info, bufnumber)
  endif

  call s:check_buffer(bufnumber, 1)
endfunction"}}}

function! s:initialize_variables() "{{{
  let s:include_info = {}
  let s:include_cache = {}
  let s:cache_accessed_time = {}
  let s:async_include_cache = {}
  let s:cached_pattern = {}
endfunction"}}}

if !exists('s:include_info')
  call s:initialize_variables()
endif

let &cpo = s:save_cpo
unlet s:save_cpo

" vim: foldmethod=marker
