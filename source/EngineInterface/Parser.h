#pragma once

#include <boost/property_tree/ptree.hpp>

#include "Definitions.h"
#include "DllExport.h"

class Parser
{
public:
    ENGINEINTERFACE_EXPORT static boost::property_tree::ptree encode(uint64_t timestep, Settings parameters);
    ENGINEINTERFACE_EXPORT static std::pair<uint64_t, Settings> decodeTimestepAndSettings(
        boost::property_tree::ptree tree);

private:
    enum class Task
    {
        Encode,
        Decode
    };
    ENGINEINTERFACE_EXPORT static void
    encodeDecode(boost::property_tree::ptree& tree, uint64_t& timestep, Settings& settings, Task task);

    template<typename T>
    ENGINEINTERFACE_EXPORT static void encodeDecode(
        boost::property_tree::ptree& tree,
        T& parameter,
        T const& defaultValue,
        std::string const& node,
        Task task);
};
