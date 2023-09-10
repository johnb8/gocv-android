package gocvtest

import "gocv.io/x/gocv"

func GetOpenCVVersion() string {
	return gocv.OpenCVVersion()
}
