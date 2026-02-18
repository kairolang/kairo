// filename: peripherals.hh
// Kairo has full native interoperability with C++.

#ifndef PERIPHERALS_HH
#define PERIPHERALS_HH

#include <string>
#include <iostream>

template <typename ConnectionType = std::string>
class Peripheral {
  public:
    explicit Peripheral(const std::string &name);
    virtual ~Peripheral()               = default;
    virtual bool        connect()       = 0;
    virtual std::string getType() const = 0;

    template <typename T = ConnectionType>
    typename std::enable_if<std::is_same<T, std::string>::value, bool>::type
    isWirelessConnection() const {
        return false;
    }

  protected:
    std::string    m_name;
    bool           m_connected = false;
    ConnectionType m_connectionType;
};

class WirelessKeyboard : public Peripheral<std::string> {
  public:
    explicit WirelessKeyboard(std::string const &name);
    bool        connect() override;
    std::string getType() const override;
    int         getBatteryLevel() const;

    template <typename T = std::string>
    bool isWirelessConnection() const {
        return true;
    }

  private:
    int m_batteryLevel = 100;
};

template <typename ConnectionType>
inline void printPeripheralType(const Peripheral<ConnectionType> &peripheral) {
    std::cout << "Peripheral type: " << peripheral.getType() << std::endl;
}

template class Peripheral<std::string>;
#endif  // PERIPHERALS_HH