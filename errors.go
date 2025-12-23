package asch

import (
	"fmt"
	"log"

	vk "github.com/tomas-mraz/vulkan"
)

func NewError(ret vk.Result) error {
	if ret != vk.Success {
		err := fmt.Errorf("vulkan error: %s (%d)", vk.Error(ret).Error(), ret)
		if Debug {
			log.Println(err)
			debug.PrintStack()
		}
		return err
	}
	return nil
}

func IfPanic(err error, finalizers ...func()) {
	if err != nil {
		for _, fn := range finalizers {
			fn()
		}
		panic(err)
	}
}
