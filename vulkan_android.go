//go:build android

package asch

import (
	vk "github.com/tomas-mraz/vulkan"
)

func NewAndroidSurface(instance vk.Instance, windowPtr uintptr) (vk.Surface, error) {
	var surface vk.Surface
	err := vk.Error(vk.CreateWindowSurface(instance, windowPtr, nil, &surface))
	if err != nil {
		return nil, err
	}
	return surface, nil
}
