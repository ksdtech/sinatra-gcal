//<![CDATA[
// Javascript for use with Schoolwires CMS.
// Rewrites "Upcoming Events" area of home page
// Redirects "Calendar" links on all pages

// Hook the func on page load 
function ksdAddOnLoadFunc(func) {
  if (window.addEventListener) {
    window.addEventListener('load', func, false);
  } else {
    window.attachEvent('onload', func);
  }
}

// Test if page is loaded with global variable
var ksdPageIsLoaded = 0;
function ksdLoadFunc() { ksdPageIsLoaded = 1; } 
ksdAddOnLoadFunc(ksdLoadFunc);

// Lightweight JSONP fetcher - www.nonobstrusive.com
var JSONP = (function(){
  var counter = 0, head, query, key, window = this;
  
  function load(url) {
    var script = document.createElement('script'), done = false;
    script.src = url;
    script.async = true;
    script.onload = script.onreadystatechange = function() {
      if (!done && (!this.readyState || this.readyState === "loaded" || this.readyState === "complete")) {
        done = true;
        script.onload = script.onreadystatechange = null;
        if (script && script.parentNode) {
          script.parentNode.removeChild(script);
        }
      }
    };
    if (!head) {
      head = document.getElementsByTagName('head')[0];
    }
    head.appendChild(script);
  }
  
  function jsonp(url, params, callback) {
    query = "?";
    params = params || {};
    for (key in params) {
      if (params.hasOwnProperty(key)) {
        query += key + "=" + params[key] + "&";
      }
    }
    var jsonp = "json" + (++counter);
    window[jsonp] = function(data) {
      callback(data);
      window[jsonp] = null;
      try {
        delete window[jsonp];
      } catch (e) {}
    };
    load(url + query + "callback=" + jsonp);
    return jsonp;
  }
  return {
    get:jsonp
  };
}());
 
// Utility functions so we don't need jQuery or other library
function childElementWithClassName(elementTag, className, parent) {
  var newEl = document.createElement(elementTag);
  if (className) {
    newEl.className = className;
  }
  if (parent) {
    parent.appendChild(newEl);
  }
  return newEl;
}

function childLink(html, href, target, color, parent) {
  var newLink = childElementWithClassName('a', null, parent);
  newLink.setAttribute('href', href); 
  if (target) {
    newLink.setAttribute('target', target);
  }
  if (color) {
    newLink.setAttribute('style', 'color: ' + color)
  }
  newLink.innerHTML = html;
  return newLink;
}

function updateEvents(data) {
  var el = document.getElementById('hp-ab4-body');
  el.innerHTML = '';
  var contDiv = childElementWithClassName('div', 'SW-Calendar-Block-Container', el); 
  var maxEvents = 25;
  for (i = 0; i < data.days.length && maxEvents != 0; i++) {
    var day = data.days[i];
    var dayDiv = childElementWithClassName('div', 'SW-Calendar-Block-Date', contDiv);
    dayDiv.innerHTML = day.display_date;
    for (j = 0; j < day.events.length && maxEvents != 0; j++) {
      maxEvents--;
      var eventDiv = childElementWithClassName('div', 'SW-Calendar-Block-Event-Container', contDiv);
      var event = day.events[j];
      var timeSpan = childElementWithClassName('span', 'SW-Calendar-Block-Time', eventDiv);
      if (event.display_time.match(/AM|PM/)) {
        var timeParts = event.display_time.split(", ", 2);
        timeSpan.innerHTML = timeParts[0] + ' ';
      }
      var titleSpan = childElementWithClassName('span', 'SW-Calendar-Block-Title', eventDiv);
      childLink(event.summary, 
        'http://kentweb.kentfieldschools.org/gcal/events/' + event.uid, '_blank', event.color, titleSpan);
    }
  }
  childElementWithClassName('br', null, contDiv);
  var calSpan = childElementWithClassName('span', 'SW-Calendar-Block-Title', contDiv);
  childLink('View Calendar',
    'http://kentweb.kentfieldschools.org/gcal/calendar', null, null, calSpan);
}
 
function changeCalendarChannel(newLink) {
  var foundDiv = 0;  var foundLink = 0;
  var allDivs = document.getElementsByTagName('div');
  for (var i = 0; !foundLink && i < allDivs.length; i++) {
    var divTest = allDivs[i];
    if (divTest.className == 'SWChannelNavigationBar') {
      foundDiv = 1;
      var channelLinks = divTest.getElementsByTagName('a');
      for (var j = channelLinks.length - 1; !foundLink && j >= 0; j--) {
        var linkTest = channelLinks[j];
        if (linkTest.title == 'Calendar') {
          foundLink = 1;
          if (newLink == null) {
            var calendarItem = linkTest.parentNode;
            var channelList = calendarItem.parentNode;
            channelList.removeChild(calendarItem);
          } else {
            linkTest.href = newLink;
            linkTest.target = 'cal';
          }
        }
      }
    }
  }
  if (!foundDiv) {
    alert("could not find nav bar");
  } else {
    if (!foundLink) {
      alert("could not find calendar link");
    }
  }
}
 
// Main function to be called when page is loaded 
function ksdPageOnLoad() {
  // FIXME: add your server name here
  changeCalendarChannel('http://example.com/gcal/calendar');
  var params = {  cals: 'all' };
  // FIXME: add your server name here
  JSONP.get('http://example.com/gcal/jsonp', params, updateEvents);
}
 
if (ksdPageIsLoaded) {
  ksdPageOnLoad();
} else {
  ksdAddOnLoadFunc(ksdPageOnLoad);
}
//]]>
