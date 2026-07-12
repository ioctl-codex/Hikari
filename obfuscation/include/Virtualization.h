//===- Virtualization.h - LLVM IR Virtualization (VMP) Pass ---------------===//
//
// Hikari extension: IR-level virtual machine protection.
// Annotate functions with "vmp" or enable globally via enable-vmp.
//
//===----------------------------------------------------------------------===//

#ifndef _HIKARI_VIRTUALIZATION_H_
#define _HIKARI_VIRTUALIZATION_H_

#include "llvm/IR/PassManager.h"
#include "llvm/Pass.h"

namespace llvm {

/// flag: enable VMP (or per-function annotate "vmp").
/// postFlatten: after successful virtualization, run CFF on the VM body
/// and helpers (combine VMP with control-flow flattening).
FunctionPass *createVirtualizationPass(bool flag, bool postFlatten = false);
void initializeVirtualizationPass(PassRegistry &Registry);

} // namespace llvm

#endif
