/*
 * fishhook.c — 运行时符号重绑定（用于 Hook libSystem 中的 C 函数）
 * 来源: facebook/fishhook (BSD License)，此处为精简可直接编译版本。
 */
#include "fishhook.h"

#include <stdbool.h>
#include <stdint.h>

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/getsect.h>

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif

struct rebindings_entry {
  struct rebinding *rebindings;
  size_t rebindings_nel;
  struct rebindings_entry *next;
};

static struct rebindings_entry *_rebindings_head;

static int prepend_rebindings(struct rebindings_entry **rebindings_head,
                              struct rebinding rebindings[],
                              size_t nel) {
  struct rebindings_entry *new_entry =
      (struct rebindings_entry *)malloc(sizeof(struct rebindings_entry));
  if (!new_entry) { return -1; }
  new_entry->rebindings =
      (struct rebinding *)malloc(sizeof(struct rebinding) * nel);
  if (!new_entry->rebindings) { free(new_entry); return -1; }
  memcpy(new_entry->rebindings, rebindings, sizeof(struct rebinding) * nel);
  new_entry->rebindings_nel = nel;
  new_entry->next = *rebindings_head;
  *rebindings_head = new_entry;
  return 0;
}

static void perform_rebinding_with_section(struct rebindings_entry *rebindings,
                                           section_t *section,
                                           intptr_t slide,
                                           nlist_t *symtab,
                                           char *strtab,
                                           unsigned int32_t *indirect_symtab,
                                           bool isConstSeg) {
  // iOS 15+ 把 __nl_symbol_ptr / __la_symbol_ptr 放在只读的 __DATA_CONST 段，
  // 必须 mprotect 才能写入。这里以“所在段是否为 __DATA_CONST”为准。
  const bool isDataConst = isConstSeg;
  unsigned int32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
  void **indirect_symbol_bindings = (void **)((unsigned intptr_t)slide + section->addr);
  for (unsigned int i = 0; i < section->size / sizeof(void *); i++) {
    unsigned int32_t symtab_index = indirect_symbol_indices[i];
    if (symtab_index == INDIRECT_SYMBOL_ABS ||
        symtab_index == INDIRECT_SYMBOL_LOCAL ||
        symtab_index == (unsigned int32_t)INDIRECT_SYMBOL_LOCAL) {
      continue;
    }
    unsigned int32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
    char *symbol_name = strtab + strtab_offset;
    if (symbol_name[0] != '_') { continue; }

    struct rebindings_entry *cur = rebindings;
    while (cur) {
      for (unsigned int j = 0; j < cur->rebindings_nel; j++) {
        if (strcmp(&symbol_name[1], cur->rebindings[j].name) == 0) {
          void *orig = indirect_symbol_bindings[i];
          if (cur->rebindings[j].replaced != NULL &&
              orig != cur->rebindings[j].replacement) {
            *(cur->rebindings[j].replaced) = orig;
          }
          if (isDataConst) {
            mprotect(indirect_symbol_bindings, section->size,
                     PROT_READ | PROT_WRITE);
            indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
            mprotect(indirect_symbol_bindings, section->size, PROT_READ);
          } else {
            indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
          }
          goto symbol_loop;
        }
      }
      cur = cur->next;
    }
  symbol_loop:;
  }
}

static void rebind_symbols_for_image(struct rebindings_entry *rebindings,
                                     const struct mach_header *header,
                                     intptr_t slide) {
  Dl_info info;
  if (dladdr(header, &info) == 0) { return; }

  segment_command_t *cur_seg_cmd;
  segment_command_t *linkedit_segment = NULL;
  struct symtab_command *symtab_cmd = NULL;
  struct dysymtab_command *dysymtab_cmd = NULL;

  unsigned intptr_t cur = (unsigned intptr_t)header + sizeof(mach_header_t);
  for (unsigned int i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_t *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
      if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
        linkedit_segment = cur_seg_cmd;
      }
    } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
      symtab_cmd = (struct symtab_command *)cur_seg_cmd;
    } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
      dysymtab_cmd = (struct dysymtab_command *)cur_seg_cmd;
    }
  }

  if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment ||
      !dysymtab_cmd->nindirectsyms) {
    return;
  }

  unsigned intptr_t linkedit_base =
      (unsigned intptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
  nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
  char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
  unsigned int32_t *indirect_symtab =
      (unsigned int32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

  cur = (unsigned intptr_t)header + sizeof(mach_header_t);
  for (unsigned int i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_t *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
      if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
          strcmp(cur_seg_cmd->segname, SEG_DATA_CONST) != 0) {
        continue;
      }
      for (unsigned int j = 0; j < cur_seg_cmd->nsects; j++) {
        section_t *sect =
            (section_t *)(cur + sizeof(segment_command_t)) + j;
        if ((sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS) {
          perform_rebinding_with_section(rebindings, sect, slide, symtab,
                                         strtab, indirect_symtab,
                                         strcmp(cur_seg_cmd->segname, SEG_DATA_CONST) == 0);
        }
        if ((sect->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) {
          perform_rebinding_with_section(rebindings, sect, slide, symtab,
                                         strtab, indirect_symtab,
                                         strcmp(cur_seg_cmd->segname, SEG_DATA_CONST) == 0);
        }
      }
    }
  }
}

static void _rebind_symbols_for_image(const struct mach_header *header,
                                      intptr_t slide) {
  rebind_symbols_for_image(_rebindings_head, header, slide);
}

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
  int retval = prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
  if (retval < 0) { return retval; }
  if (_rebindings_head->next) {
    rebind_symbols_for_image(_rebindings_head, _dyld_get_image_header(0),
                             _dyld_get_image_vmaddr_slide(0));
  } else {
    _dyld_register_func_for_add_image(_rebind_symbols_for_image);
  }
  return 0;
}
