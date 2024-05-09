

```
:noh
```

```
:set nu
```

Add this to ~/.vimrc
```
autocmd FileType yaml setlocal ts=2 sts=2 sw=2 expandtab
```

```
autocmd FileType yaml setlocal ts=2 sts=2 sw=2 et
```

```
autocmd FileType yaml setlocal ts=2 sts=2 sw=2 expandtab cursorline cursorcolumn
```

the best configurtion
```
autocmd FileType yaml setlocal ai ts=2 sw=2 et nu cuc
autocmd FileType yaml colo desert
```


To apply changes without reopening the vim
```
:source
```