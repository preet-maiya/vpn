output "public_ip" {
  value = azurerm_public_ip.pip.ip_address
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.vm.name
}

output "tailscale_hostname" {
  value = "${azurerm_linux_virtual_machine.vm.name}-exit"
}

output "function_hostname" {
  value = azurerm_linux_function_app.func.default_hostname
}
