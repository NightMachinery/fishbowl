import { Button } from "@material-ui/core"
import LocalCafeOutlinedIcon from "@material-ui/icons/LocalCafeOutlined"
import * as React from "react"

interface Props {
  children: string
}

function BuyMeACoffeeButton(props: Props) {
  return (
    <Button
      color="primary"
      component="a"
      href="https://www.buymeacoffee.com/fishbowlgame"
      rel="noreferrer noopener"
      startIcon={<LocalCafeOutlinedIcon />}
      target="_blank"
      variant="contained"
    >
      {props.children}
    </Button>
  )
}

export default BuyMeACoffeeButton
