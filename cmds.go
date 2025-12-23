// Copyright (c) 2025 Cubyte.online under the AGPL License
// Copyright (c) 2022 Cogent Core. under the BSD-style License
// Copyright (c) 2017 Maxim Kupriianov <max@kc.vc>, under the MIT License

package asch

import (
	vk "github.com/tomas-mraz/vulkan"
)

// CmdPool is a command pool and buffer
type CmdPool struct {
	Pool vk.CommandPool
	Buff vk.CommandBuffer
}

// EndCmd does EndCommandBuffer on buffer
func (cp *CmdPool) EndCmd() {
	CmdEnd(cp.Buff)
}

// CmdEnd does EndCommandBuffer on buffer
func CmdEnd(cmd vk.CommandBuffer) {
	ret := vk.EndCommandBuffer(cmd)
	IfPanic(NewError(ret))
}
