# VIM Configurations for YAML files
```
:set expandtab
:set tabstop=2
:set shiftwidth=2
:colorscheme <scheme-name>

```

To see the available color schemes, you can run the following command:
```
:colorscheme <space> <Ctrl-d>
```

```
vim .vimrc
```

```
autocmd FileType yaml setlocal ts=2 sts=2 sw=2 expandtab
colo elflord
```

```
echo 'autocmd FileType yaml setlocal ts=2 sts=2 sw=2 expandtab' >> .vimrc
```